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
    /// Raw sender MRI (`8:orgid:…`) when the event carried one; nil on
    /// old core builds and non-MRI senders. Presence resolves it for
    /// live chatmate dots.
    public let senderID: String?
    public let text: String
    public let time: String
    public let isEdit: Bool
    public let editedID: String?
    /// Unstripped server HTML (om-richmedia: streaming `<img>` mining).
    /// Nil on old core builds — treat as text-only.
    public let raw: String?
    /// Raw `messagetype` (e.g. `Text`, `RichText/Html`). Nil on old core
    /// builds — the rules filter treats that as unclassifiable (the type
    /// gate passes) rather than skipping.
    public let messageType: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case msgId = "id"
        case sender, senderID = "sender_id", text, time
        case isEdit = "is_edit"
        case editedID = "edited_id"
        case raw
        case messageType = "message_type"
    }

    /// Host-side construction (tests, mock feeds). `senderID`/`raw`/
    /// `messageType` default to nil (old core builds omit them); wire
    /// decoding untouched.
    public init(
        chatID: String, msgId: String, sender: String,
        senderID: String? = nil, text: String, time: String,
        isEdit: Bool, editedID: String? = nil, raw: String? = nil,
        messageType: String? = nil
    ) {
        self.chatID = chatID
        self.msgId = msgId
        self.sender = sender
        self.senderID = senderID
        self.text = text
        self.time = time
        self.isEdit = isEdit
        self.editedID = editedID
        self.raw = raw
        self.messageType = messageType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try c.decode(String.self, forKey: .chatID)
        msgId = try c.decode(String.self, forKey: .msgId)
        sender = try c.decode(String.self, forKey: .sender)
        senderID = try c.decodeIfPresent(String.self, forKey: .senderID)
        text = try c.decode(String.self, forKey: .text)
        time = try c.decode(String.self, forKey: .time)
        isEdit = try c.decode(Bool.self, forKey: .isEdit)
        editedID = try c.decodeIfPresent(String.self, forKey: .editedID)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        messageType = try c.decodeIfPresent(String.self, forKey: .messageType)
    }

    /// True when this event belongs to the given open chat.
    /// Nil (nothing open) never matches.
    public func isFor(chatID id: String?) -> Bool {
        id.map { $0 == chatID } ?? false
    }

    /// Host model: edits collapse onto the edited id so
    /// `ConversationStore.ingest` updates the bubble in place.
    /// `raw` rides along so streaming image bubbles render (same key as
    /// history, so the cache never refetches on resync).
    public var asChatMessage: ChatMessage {
        if isEdit, let edited = editedID {
            return ChatMessage(id: edited, sender: sender, timestamp: time, content: text, raw: raw)
        }
        return ChatMessage(id: msgId, sender: sender, timestamp: time, content: text, raw: raw)
    }
}

/// Typed poll envelope from ostmac_trouter_poll_typed.
/// `calls` is nil on old core builds (pre om-signal) — treat as no events.
public struct RealtimePoll: Decodable, Sendable {
    public let ok: Bool
    public let messages: [RealtimeMessage]
    public let resync: Bool
    public let skipped: Int
    public let calls: [CallEvent]?

    public init(ok: Bool, messages: [RealtimeMessage], resync: Bool, skipped: Int, calls: [CallEvent]? = nil) {
        self.ok = ok
        self.messages = messages
        self.resync = resync
        self.skipped = skipped
        self.calls = calls
    }
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
    private var callSubs: [UUID: @Sendable (CallEvent) -> Void] = [:]
    private var attempt = 0
    private var pollCountValue = 0
    private var lastErrorValue: String?

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

    /// Completed typed polls since init (includes the start drain).
    /// The UI reads this to prove the poll loop is alive.
    public var pollCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pollCountValue
    }

    /// Last poll failure, cleared on the next success. Nil when healthy.
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastErrorValue
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

    /// Subscribe to call events (incoming invitation / remote end).
    /// The core already recorded them in the call slot; the handler
    /// just refreshes UI state.
    @discardableResult
    public func onCall(_ h: @escaping @Sendable (CallEvent) -> Void) -> UUID {
        let t = UUID()
        lock.lock(); callSubs[t] = h; lock.unlock()
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
        do {
            let r = try pollDeduped(notify: true)
            lock.lock(); lastErrorValue = nil; lock.unlock()
            return r
        } catch {
            lock.lock(); lastErrorValue = String(describing: error); lock.unlock()
            throw error
        }
    }

    private func pollDeduped(notify: Bool) throws -> (messages: Int, resync: Bool) {
        let p = try pollFn()
        lock.lock(); pollCountValue += 1; lock.unlock()
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
        let callHandlers = Array(callSubs.values)
        let callEvents = p.calls ?? []
        lock.unlock()
        if notify {
            for m in fresh { for h in msgHandlers { h(m) } }
            for h in rsHandlers { h() }
            for e in callEvents { for h in callHandlers { h(e) } }
        }
        return (fresh.count, p.resync)
    }
}
