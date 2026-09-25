// CallHistory.swift — om-call-history: local recent-calls list.
//
// Records finished calls (missed/incoming/outgoing with name, time,
// duration) in a UserDefaults-backed store, newest first. Feeds from two
// seams: feed CallEvents (incoming rings, remote end/reject) and CallStore
// slot snapshots (connect flips, local end). Each call id records exactly
// once; a cap keeps the plist small. Redial re-places through the
// injected handler (AppState wires CallStore.place); rows without a
// thread id can't redial (incoming legs carry no thread).
//
//   let history = CallHistoryStore()
//   history.noteEvent(ev) // feed onCall
//   history.noteActiveCall(callStore.call) // $call sink
//   history.onRedial = { call.place(threadID: $0.thread) }
//
// Threading: @MainActor (ObservableObject for the window + Diagnostics).
// No core calls, no chat-list touches; counters surface in Diagnostics.
import DietDesign
import Foundation
import SwiftUI

/// Direction of a finished call. Raw values are the CallInfo `dir`
/// vocabulary plus `missed` (incoming, never connected).
public enum CallDirection: String, Codable, Sendable, Equatable {
    case missed
    case incoming = "in"
    case outgoing = "out"

    /// SF Symbol for the recents row (missed renders in danger red).
    public var systemImage: String {
        switch self {
        case .missed: "phone.arrow.down.left.fill"
        case .incoming: "phone.arrow.down.left"
        case .outgoing: "phone.arrow.up.right"
        }
    }

    /// VoiceOver + Diagnostics word.
    public var label: String {
        switch self {
        case .missed: "Missed"
        case .incoming: "Incoming"
        case .outgoing: "Outgoing"
        }
    }
}

/// One finished call. Unix-second stamps (UTC, DST-proof); labels are
/// derived host-side. `thread` is empty on incoming legs (no redial).
public struct CallRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let direction: CallDirection
    public let peer: String
    public let peerName: String
    public let thread: String
    public let startedAt: UInt64
    public let endedAt: UInt64
    /// Connected seconds; 0 when the call never connected.
    public let durationSecs: UInt64

    public init(
        id: String, direction: CallDirection,
        peer: String = "", peerName: String = "", thread: String = "",
        startedAt: UInt64, endedAt: UInt64, durationSecs: UInt64 = 0
    ) {
        self.id = id
        self.direction = direction
        self.peer = peer
        self.peerName = peerName
        self.thread = thread
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSecs = durationSecs
    }

    public var isMissed: Bool { direction == .missed }

    /// Name, else MRI, else thread (CallInfo.displayPeer rules).
    public var displayName: String {
        if !peerName.isEmpty { return peerName }
        if !peer.isEmpty { return peer }
        return thread
    }

    /// Start time: "12:53" today, else "12:53 22 Sep" (ChatMessage rules).
    public var displayTime: String {
        Self.displayTime(
            for: Date(timeIntervalSince1970: TimeInterval(startedAt)))
    }

    /// Shared clock/day formatters (om-s6-renderparse): locked pair,
    /// timezone refreshed per call (same strings, no per-call allocs).
    private static let clockFormats = CallClockFormats()

    public static func displayTime(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let clock = clockFormats.clock(from: date)
        if cal.isDate(date, inSameDayAs: now) { return clock }
        return "\(clock) \(clockFormats.day(from: date))"
    }

    /// "0:43", "12:05", "1:02:03" (hours only when non-zero).
    public var durationLabel: String { Self.durationLabel(durationSecs) }

    public static func durationLabel(_ secs: UInt64) -> String {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "Missed · 12:53" / "Doe, Jane · 0:43 · 12:53 22 Sep" row subtitle.
    public var detailLine: String {
        if isMissed { return "Missed · \(displayTime)" }
        if durationSecs == 0 { return "\(direction.label) · \(displayTime)" }
        return "\(direction.label) · \(durationLabel) · \(displayTime)"
    }
}

/// In-flight call: ringing snapshot + optional connect mark. In-memory
/// only — a relaunch mid-call still finalizes from the slot snapshot.
struct PendingCall: Equatable {
    var peer: String
    var peerName: String
    var thread: String
    var dir: String
    var ringingAt: Date
    var connectedAt: Date?
}

/// Local recents: UserDefaults JSON array, newest first, capped.
@MainActor
public final class CallHistoryStore: ObservableObject {
    /// Newest first. Published for the window; Diagnostics reads counts.
    @Published public private(set) var records: [CallRecord] = []
    /// Redial seam (AppState: place on the record's thread). Injectable
    /// so tests assert the action without the call slot.
    public var onRedial: ((CallRecord) -> Void)?

    public static let defaultsKey = "omCallHistoryV1"
    /// Per-account key (d1-accounts): default keeps the legacy key.
    nonisolated public static func key(for accountID: String) -> String {
        AccountProfile.key(defaultsKey, for: accountID)
    }
    public static let maxRecords = 100

    private let defaults: UserDefaults
    private let key: String
    private var pending: [String: PendingCall] = [:]
    /// Finalized ids (session exactly-once; seeded from loaded records).
    private var recordedIDs: Set<String> = []

    public init(
        defaults: UserDefaults = .standard,
        key: String = CallHistoryStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
        let loaded = Self.load(defaults: defaults, key: key)
        records = loaded
        recordedIDs = Set(loaded.map(\.id))
    }

    // MARK: - Counts (Diagnostics only)

    public var totalCount: Int { records.count }
    public var missedCount: Int { records.filter(\.isMissed).count }
    public var isEmpty: Bool { records.isEmpty }

    // MARK: - Feeds

    /// Slot snapshot hook (CallStore.$call sink): active states refresh
    /// the pending entry, ended/failed finalizes it, nil finalizes all
    /// pending (demo end + slot-clear paths).
    public func noteActiveCall(_ call: CallInfo?, at now: Date = Date()) {
        guard let call else {
            for id in pending.keys { finalize(id: id, snapshot: nil, at: now) }
            return
        }
        if call.isActive {
            var p = pending[call.id] ?? PendingCall(
                peer: call.peer, peerName: call.peerName,
                thread: call.thread, dir: call.dir,
                ringingAt: stampOr(call.startedAt, now))
            p.peer = call.peer.isEmpty ? p.peer : call.peer
            p.peerName = call.peerName.isEmpty ? p.peerName : call.peerName
            p.thread = call.thread.isEmpty ? p.thread : call.thread
            if !call.dir.isEmpty { p.dir = call.dir }
            if call.state == "connected", p.connectedAt == nil {
                p.connectedAt = now
            }
            pending[call.id] = p
            return
        }
        if call.state == "ended" || call.state == "failed" {
            finalize(id: call.id, snapshot: call, at: now)
        }
    }

    /// Feed event hook (RealtimeFeed.onCall): incoming opens pending,
    /// end/rejected finalize it. Events without pending are ignored
    /// (the slot snapshot carries the authoritative close).
    public func noteEvent(_ event: CallEvent, at now: Date = Date()) {
        switch event.kind {
        case "incoming":
            if pending[event.callID] == nil {
                pending[event.callID] = PendingCall(
                    peer: event.peer, peerName: event.peerName,
                    thread: "", dir: "in", ringingAt: now)
            }
        case "end", "rejected":
            if pending[event.callID] != nil {
                finalize(id: event.callID, snapshot: nil, at: now)
            }
        default:
            break
        }
    }

    // MARK: - Actions

    /// Redial hook: fires the handler (no-op when unset). Callers gate
    /// on `canRedial` — threadless rows can't place.
    public func redial(_ record: CallRecord) {
        onRedial?(record)
    }

    /// Pure redial gate: the record carries a placeable thread id.
    nonisolated public static func canRedial(_ record: CallRecord) -> Bool {
        !record.thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func canRedial(_ record: CallRecord) -> Bool {
        Self.canRedial(record)
    }

    /// Drop every record (in-flight pending survives: the live call
    /// still lands when it ends). Persists immediately.
    public func clear() {
        let ids = Set(records.map(\.id))
        records = []
        recordedIDs.subtract(ids)
        save()
    }

    /// Offline demo recents (missed + in + out, one threadless row).
    /// In-memory only — demo never touches the persisted list.
    public func seedDemo() {
        let now = UInt64(Date().timeIntervalSince1970)
        records = [
            CallRecord(
                id: "demo-missed", direction: .missed,
                peer: "8:orgid:demo-missed", peerName: "Garcia, Maria",
                startedAt: now - 900, endedAt: now - 870),
            CallRecord(
                id: "demo-in", direction: .incoming,
                peer: "8:orgid:demo", peerName: "Doe, Jane",
                thread: "19:demo@thread.v2",
                startedAt: now - 7200, endedAt: now - 6943,
                durationSecs: 257),
            CallRecord(
                id: "demo-out", direction: .outgoing,
                peer: "8:orgid:demo-chen", peerName: "Chen, Tom",
                thread: "19:demo-chen@thread.v2",
                startedAt: now - 96_000, endedAt: now - 95_372,
                durationSecs: 628),
        ]
        recordedIDs = Set(records.map(\.id))
    }

    // MARK: - Internals

    /// Append the finished record for `id`, exactly once. Prefers the
    /// pending entry (has the connect mark); falls back to the slot
    /// snapshot (relaunch-then-end edge: unobserved leg, 0 duration).
    private func finalize(id: String, snapshot: CallInfo?, at now: Date) {
        guard !recordedIDs.contains(id) else {
            pending.removeValue(forKey: id)
            return
        }
        let p = pending.removeValue(forKey: id)
        let dir = p?.dir ?? snapshot?.dir ?? ""
        let connected = p?.connectedAt != nil
        let direction: CallDirection =
            dir == "in" ? (connected ? .incoming : .missed) : .outgoing
        let started: UInt64 = {
            if let p { return UInt64(p.ringingAt.timeIntervalSince1970) }
            if let s = snapshot, s.startedAt > 0 { return s.startedAt }
            return UInt64(now.timeIntervalSince1970)
        }()
        let ended = UInt64(now.timeIntervalSince1970)
        let duration: UInt64 = {
            guard connected, let at = p?.connectedAt else { return 0 }
            return UInt64(max(0, now.timeIntervalSince(at)))
        }()
        let record = CallRecord(
            id: id, direction: direction,
            peer: p?.peer ?? snapshot?.peer ?? "",
            peerName: p?.peerName ?? snapshot?.peerName ?? "",
            thread: p?.thread ?? snapshot?.thread ?? "",
            startedAt: started, endedAt: max(ended, started),
            durationSecs: duration)
        recordedIDs.insert(id)
        records.removeAll { $0.id == id }
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            let dropped = records.suffix(from: Self.maxRecords)
            recordedIDs.subtract(dropped.map(\.id))
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
    }

    private func stampOr(_ unix: UInt64, _ fallback: Date) -> Date {
        unix > 0
            ? Date(timeIntervalSince1970: TimeInterval(unix)) : fallback
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }

    static func load(defaults: UserDefaults, key: String) -> [CallRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CallRecord].self, from: data)) ?? []
    }
}

// MARK: - Window

/// Recent Calls window: missed/incoming/outgoing rows (name, time,
/// duration) with per-row redial + Clear History. Empty store shows
/// real guidance, never a bare list.
public struct CallHistoryView: View {
    @ObservedObject public var store: CallHistoryStore
    @State private var confirmClear = false

    public init(store: CallHistoryStore) {
        self.store = store
    }

    /// Empty-state copy (single source; the store tests pin it).
    public static let emptyImage = "phone"
    public static let emptyTitle = "No recent calls"
    public static let emptyMessage =
        "Calls you make or receive will appear here with names, times, and durations."

    public var body: some View {
        Group {
            if store.records.isEmpty {
                DietEmptyState(
                    systemImage: Self.emptyImage,
                    title: Self.emptyTitle,
                    message: Self.emptyMessage)
            } else {
                List(store.records) { record in
                    HStack(spacing: DietSpace.sm) {
                        Image(systemName: record.direction.systemImage)
                            .font(.system(size: DietSize.iconMD))
                            .foregroundStyle(tint(for: record))
                            .frame(width: DietSize.iconLG)
                            .accessibilityLabel(record.direction.label)
                        VStack(alignment: .leading, spacing: DietSpace.xxs) {
                            Text(record.displayName)
                                .font(DietType.body)
                                .foregroundStyle(DietColor.textPrimaryColor)
                                .lineLimit(1)
                            Text(record.detailLine)
                                .font(DietType.caption1)
                                .foregroundStyle(missedSecondary(record))
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Redial") { store.redial(record) }
                            .buttonStyle(.link)
                            .disabled(!store.canRedial(record))
                            .help(redialHelp(for: record))
                    }
                    .padding(.vertical, DietSpace.xxs)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Recent Calls")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History") { confirmClear = true }
                    .disabled(store.records.isEmpty)
                    .help("Remove all recent calls from this Mac")
            }
        }
        .confirmationDialog(
            "Clear all recent calls?", isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every entry on this Mac. It can't be undone.")
        }
        .frame(minWidth: 320, minHeight: 300)
    }

    private func tint(for record: CallRecord) -> Color {
        record.isMissed
            ? Color(nsColor: DietColor.danger)
            : DietColor.textSecondaryColor
    }

    private func missedSecondary(_ record: CallRecord) -> Color {
        record.isMissed
            ? Color(nsColor: DietColor.danger)
            : DietColor.textSecondaryColor
    }

    private func redialHelp(for record: CallRecord) -> String {
        store.canRedial(record)
            ? "Call \(record.displayName) back"
            : "No thread to call back on"
    }
}

/// Shared call-clock formatters (om-s6-renderparse). DateFormatter is not
/// thread-safe, so every use runs under the lock with a refreshed
/// timezone (same strings as a fresh formatter, none of the allocs).
private final class CallClockFormats {
    private let lock = NSLock()
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    func clock(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        clock.timeZone = TimeZone.current
        return clock.string(from: date)
    }

    func day(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        day.timeZone = TimeZone.current
        return day.string(from: date)
    }
}
