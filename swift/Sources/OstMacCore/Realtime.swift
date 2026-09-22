// Realtime.swift — live Trouter event feed for the conversation view.
//
// RealtimeFeed polls the typed poll endpoint, dedupes by message id,
// reconnects with backoff, and dispatches to subscribers:
//
//   let feed = RealtimeFeed()
//   feed.subscribe { msg in view.apply(msg) }   // typed message/edit
//   feed.onResync { view.refetchVisibleChats() } // message_loss gap
//   feed.start()
//
// message_loss behavior: the server emits trouter.message_loss when it drops
// queued indicators (backpressure, reconnect gap, stale etag). The Rust core
// surfaces this as RealtimePoll.resync; the feed forwards it to resync
// handlers. The socket itself is healthy, so the feed does NOT reconnect on
// resync — the UI re-fetches visible conversations via the chat API instead.
// Resync may repeat with identical etags; that is server steady-state.
//
// Threading: polling runs on a private queue; subscriber/resync handlers are
// invoked on that queue — hop to MainActor in UI code. All state is locked.
import Foundation

/// One chat message (or edit) from the live feed. Decodes the Rust core's
/// typed poll envelope; field names are the core's JSON keys.
public struct RealtimeMessage: Decodable, Sendable, Identifiable {
    public var id: String { msgId }
    public let chatID: String
    public let msgId: String
    public let sender: String
    public let text: String
    public let time: String
    public let isEdit: Bool
    public let editedID: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case msgId = "id"
        case sender, text, time
        case isEdit = "is_edit"
        case editedID = "edited_id"
    }
}

/// Typed poll envelope from ostmac_trouter_poll_typed.
public struct RealtimePoll: Decodable, Sendable {
    public let ok: Bool
    public let messages: [RealtimeMessage]
    public let resync: Bool
    public let skipped: Int
}

/// Pure reconnect backoff: 1,2,4,8,16,30,30,… seconds. Deterministic
/// (no jitter) so retries are testable and log-readable.
public enum RealtimeBackoff {
    public static let cap: Double = 30

    public static func delay(forAttempt attempt: Int) -> Double {
        guard attempt > 0 else { return 1 }
        return min(cap, pow(2.0, Double(min(attempt, 10) - 1)))
    }

    /// Map a trouter_start return code to feed action.
    /// 0/-1 = live (started / already running); anything else = retry.
    public static func shouldRetry(startCode rc: Int32) -> Bool {
        rc != 0 && rc != -1
    }
}

public final class RealtimeFeed: @unchecked Sendable {
    public enum State: Sendable { case stopped, live, retryWait }

    /// Max seen ids kept for dedupe; oldest evicted first.
    public static let dedupeCap = 2048

    private let lock = NSLock()
    private var state: State = .stopped
    private var generation = 0 // invalidates timers/retries on stop
    private var timer: DispatchSourceTimer?
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var subs: [UUID: @Sendable (RealtimeMessage) -> Void] = [:]
    private var resyncSubs: [UUID: @Sendable () -> Void] = [:]
    private var attempt = 0

    private let pollFn: @Sendable () throws -> RealtimePoll
    private let startFn: @Sendable () -> Int32
    private let stopFn: @Sendable () -> Int32
    private let queue: DispatchQueue
    public var pollInterval: TimeInterval = 1.0

    public init(
        poll: @escaping @Sendable () throws -> RealtimePoll = { try RustCore.trouterPollTyped() },
        start: @escaping @Sendable () -> Int32 = { RustCore.trouterStart() },
        stop: @escaping @Sendable () -> Int32 = { RustCore.trouterStop() }
    ) {
        self.pollFn = poll
        self.startFn = start
        self.stopFn = stop
        self.queue = DispatchQueue(label: "RealtimeFeed", qos: .utility)
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Subscribe to typed message/edit events. Returns a token for unsubscribe.
    @discardableResult
    public func subscribe(_ h: @escaping @Sendable (RealtimeMessage) -> Void) -> UUID {
        let t = UUID()
        lock.lock(); subs[t] = h; lock.unlock()
        return t
    }

    public func unsubscribe(_ t: UUID) {
        lock.lock(); subs.removeValue(forKey: t); lock.unlock()
    }

    /// Subscribe to resync signals (message_loss gap — re-fetch chats).
    @discardableResult
    public func onResync(_ h: @escaping @Sendable () -> Void) -> UUID {
        let t = UUID()
        lock.lock(); resyncSubs[t] = h; lock.unlock()
        return t
    }

    public func start() {
        lock.lock()
        guard state == .stopped else { lock.unlock(); return }
        generation += 1
        let gen = generation
        attempt = 0
        lock.unlock()
        attemptStart(gen: gen)
    }

    public func stop() {
        lock.lock()
        generation += 1
        state = .stopped
        timer?.cancel(); timer = nil
        lock.unlock()
        _ = stopFn()
    }

    /// One start attempt; on failure schedules a backoff retry.
    private func attemptStart(gen: Int) {
        let rc = startFn()
        lock.lock()
        guard gen == generation else { lock.unlock(); return } // stopped meanwhile
        if !RealtimeBackoff.shouldRetry(startCode: rc) {
            state = .live
            attempt = 0
            lock.unlock()
            // Drain stale backlog without notifying, then go live.
            _ = try? pollDeduped(notify: false)
            scheduleTimer(gen: gen)
            return
        }
        state = .retryWait
        attempt += 1
        let wait = RealtimeBackoff.delay(forAttempt: attempt)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.attemptStart(gen: gen)
        }
    }

    private func scheduleTimer(gen: Int) {
        lock.lock()
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick(gen: gen) }
        timer = t
        lock.unlock()
        t.resume()
    }

    private func tick(gen: Int) {
        lock.lock()
        guard gen == generation, state == .live else { lock.unlock(); return }
        lock.unlock()
        _ = try? pollOnce()
    }

    /// Single poll: dedupe + dispatch. Returns (new messages, resync).
    /// Public so the UI (and tests) can drive polling manually.
    @discardableResult
    public func pollOnce() throws -> (messages: Int, resync: Bool) {
        try pollDeduped(notify: true)
    }

    private func pollDeduped(notify: Bool) throws -> (messages: Int, resync: Bool) {
        let p = try pollFn()
        var fresh: [RealtimeMessage] = []
        lock.lock()
        for m in p.messages where !seen.contains(m.msgId) {
            seen.insert(m.msgId)
            seenOrder.append(m.msgId)
            if seenOrder.count > Self.dedupeCap {
                seen.remove(seenOrder.removeFirst())
            }
            fresh.append(m)
        }
        let msgHandlers = Array(subs.values)
        let rsHandlers = p.resync ? Array(resyncSubs.values) : []
        lock.unlock()
        if notify {
            for m in fresh { for h in msgHandlers { h(m) } }
            for h in rsHandlers { h() }
        }
        return (fresh.count, p.resync)
    }
}
