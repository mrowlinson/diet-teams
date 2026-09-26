// UnreadStore.swift — om-notifbadge: rules-driven unread + dock badge.
//
// Counts accrue ONLY on ChatFilter .notify; every .skip (mute,
// teams-mute, keyword-block, structural bodies, own/type/edit/noisy,
// meeting-suppressed) leaves counts and the dock untouched. The open
// chat never accrues (its bubbles are already visible); opening a chat
// marks it read. Dock badge = total unread, cleared at zero.
//
//   let unread = UnreadStore() // live dock badge
//   unread.ingest(decision: decision, chatID: msg.chatID, openChatID: openChatID)
//   unread.markRead(chatID: id) // on open
//
// om-markunread: manual mark-as-unread/read rides a per-thread read
// horizon override (`overrides`). `markUnread` pins a thread unread at
// its current tail (badge shows at least 1); the sidebar badge reads
// the visible count in place (no list refetch, no reorder — the
// ChatListViewModel is untouched); opening the thread clears the
// override via the same `markRead` the open path already calls.
// Threading: @MainActor (ObservableObject for the sidebar + NSApp dock).
// The dock sink is injectable for tests (FakeDockBadge records labels).
import AppKit
import Foundation

/// Dock badge sink: the real dock tile or an in-memory fake.
public protocol DockBadging: Sendable {
    func setBadge(_ label: String?)
}

/// Live sink over the app dock tile. Hops to the main thread (AppKit).
/// Uses NSApplication.shared (never the NSApp global, which traps when
/// no app object exists — e.g. store tests running outside the app).
public final class SystemDockBadge: DockBadging, @unchecked Sendable {
    public init() {}

    public func setBadge(_ label: String?) {
        let value = label ?? ""
        if Thread.isMainThread {
            NSApplication.shared.dockTile.badgeLabel = value
        } else {
            DispatchQueue.main.sync { NSApplication.shared.dockTile.badgeLabel = value }
        }
    }
}

/// In-memory sink (tests): records every label set.
public final class FakeDockBadge: DockBadging, @unchecked Sendable {
    private let lock = NSLock()
    private var _labels: [String?] = []

    public init() {}

    public func setBadge(_ label: String?) {
        lock.lock(); defer { lock.unlock() }
        _labels.append(label)
    }

    public var labels: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _labels
    }
}

/// Per-chat unread counts + dock badge, driven by rules decisions.
@MainActor
public final class UnreadStore: ObservableObject {
    /// Unread per chat id. Zero-count chats are absent, never stored as 0.
    @Published public private(set) var counts: [String: Int] = [:]
    /// Manual read-horizon overrides (om-markunread): threads pinned
    /// unread via Mark as Unread. Cleared ids are absent, never stored
    /// empty. Client-side only (never sent to core); opening a thread
    /// clears its override via `markRead`.
    @Published public private(set) var overrides: Set<String> = []

    private let dock: any DockBadging

    /// Nonisolated so views can take a default `UnreadStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(dock: (any DockBadging)? = nil) {
        self.dock = dock ?? SystemDockBadge()
    }

    /// Total unread across chats (the dock number), overrides included:
    /// each overridden thread contributes at least 1.
    public var total: Int {
        Self.visibleTotal(counts: counts, overrides: overrides)
    }

    /// Chats with a visible badge (Diagnostics count), overrides included.
    public var chatCount: Int {
        Self.visibleChats(counts: counts, overrides: overrides)
    }

    /// Dock label for the current total: nil at zero (clears the tile).
    public var badgeLabel: String? {
        Self.badgeLabel(forTotal: total)
    }

    /// Pure label: nil at zero, else the decimal total.
    nonisolated public static func badgeLabel(forTotal total: Int) -> String? {
        total > 0 ? "\(total)" : nil
    }

    /// Pure visible count for one thread (om-markunread badge math): the
    /// auto count, floored at 1 while its horizon override stands. An
    /// override absorbs the first auto point (mark-unread then one new
    /// message still shows 1, not 2); further accruals count past it.
    nonisolated public static func visibleCount(auto: Int, overridden: Bool) -> Int {
        overridden ? max(auto, 1) : max(auto, 0)
    }

    /// Pure visible total over every thread (the dock number).
    nonisolated public static func visibleTotal(counts: [String: Int], overrides: Set<String>) -> Int {
        var total = 0
        for (id, auto) in counts {
            total += visibleCount(auto: auto, overridden: overrides.contains(id))
        }
        for id in overrides where counts[id] == nil {
            total += 1
        }
        return total
    }

    /// Pure visible chat count: threads with a badge (auto or override).
    nonisolated public static func visibleChats(counts: [String: Int], overrides: Set<String>) -> Int {
        var ids = Set(counts.keys)
        ids.formUnion(overrides)
        return ids.count
    }

    /// Pure accrual gate: notify counts unless the chat is already open
    /// (visible bubbles) or the id is blank. Every skip never counts.
    /// `visibleChatIDs` (e1-popout: main-open + popped) extends the
    /// open-chat exemption to pop-out windows.
    nonisolated public static func shouldCount(
        decision: ChatFilter.Decision, chatID: String, openChatID: String?,
        visibleChatIDs: Set<String> = []
    ) -> Bool {
        guard case .notify = decision else { return false }
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if visibleChatIDs.contains(chatID) { return false }
        if let open = openChatID, open == chatID { return false }
        return true
    }

    /// Accrue one rules decision for a chat. Skips and open-chat
    /// notifies are no-ops (no dock write). Accruals that leave the
    /// visible total unchanged (an override absorbing the first point)
    /// also skip the dock write.
    public func ingest(
        decision: ChatFilter.Decision, chatID: String, openChatID: String?,
        visibleChatIDs: Set<String> = []
    ) {
        guard Self.shouldCount(
            decision: decision, chatID: chatID, openChatID: openChatID,
            visibleChatIDs: visibleChatIDs) else { return }
        let before = total
        counts[chatID, default: 0] += 1
        if total != before {
            syncDock()
        }
    }

    /// Convenience: decide via ChatFilter (stateful meeting window),
    /// accrue, and return the decision so the caller reuses it for the
    /// banner (one decide per event — never double-claim the window).
    @discardableResult
    public func ingest(
        message: RealtimeMessage, chatDisplayName: String,
        ownerMRI: String?, rules: RulesConfig,
        meetingDedup: inout MeetingStartDedup, now: Date,
        openChatID: String?, teamsMutedChatIDs: Set<String> = [],
        dndActive: Bool = false, quietActive: Bool = false,
        snoozedChatIDs: Set<String> = [],
        visibleChatIDs: Set<String> = []
    ) -> ChatFilter.Decision {
        let decision = ChatFilter.decide(
            message: message, chatDisplayName: chatDisplayName,
            ownerMRI: ownerMRI, rules: rules,
            meetingDedup: &meetingDedup, now: now,
            teamsMutedChatIDs: teamsMutedChatIDs,
            dndActive: dndActive, quietActive: quietActive,
            snoozedChatIDs: snoozedChatIDs)
        ingest(
            decision: decision, chatID: message.chatID, openChatID: openChatID,
            visibleChatIDs: visibleChatIDs)
        return decision
    }

    /// Unread for one chat (0 when absent). Overrides floor the
    /// visible count at 1; the sidebar badge reads this in place.
    public func count(for chatID: String) -> Int {
        Self.visibleCount(
            auto: counts[chatID] ?? 0,
            overridden: overrides.contains(chatID))
    }

    /// True while a horizon override stands for this thread.
    public func isOverridden(chatID: String) -> Bool {
        overrides.contains(chatID)
    }

    /// True while the thread shows a badge (auto or override).
    public func isUnread(chatID: String) -> Bool {
        count(for: chatID) > 0
    }

    /// Pin a thread unread at its current tail (om-markunread): the
    /// badge shows at least 1 until the thread opens. Blank ids and
    /// re-marks are no-ops (no dock write); marking an already-unread
    /// thread still records the override (clearing stays one open) but
    /// skips the dock write when the visible total is unchanged. Never
    /// touches the chat list — the badge updates in place.
    public func markUnread(chatID: String) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard !overrides.contains(id) else { return }
        let before = total
        overrides.insert(id)
        if total != before {
            syncDock()
        }
    }

    /// Seed counts accrued while another account was active (gap-g1
    /// switch handoff: the background roll-up drains here so the switch
    /// lands on unread N). Merges additively; blank ids and non-positive
    /// counts are dropped. Empty input is a no-op (no dock write).
    public func ingestBackground(_ counts: [String: Int]) {
        let clean = counts.filter {
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value > 0
        }
        guard !clean.isEmpty else { return }
        let before = total
        for (id, n) in clean {
            self.counts[id, default: 0] += n
        }
        if total != before {
            syncDock()
        }
    }

    /// Opening a chat marks it read: drops its auto count AND its
    /// horizon override, syncs the dock. Unknown ids are a no-op (no
    /// dock write).
    public func markRead(chatID: String) {
        let hadCount = counts.removeValue(forKey: chatID) != nil
        let hadOverride = overrides.remove(chatID) != nil
        guard hadCount || hadOverride else { return }
        syncDock()
    }

    /// Clear every chat (sign-out): counts and overrides. Empty is a
    /// no-op (no dock write).
    public func markAllRead() {
        guard !counts.isEmpty || !overrides.isEmpty else { return }
        counts.removeAll()
        overrides.removeAll()
        syncDock()
    }

    private func syncDock() {
        dock.setBadge(badgeLabel)
    }
}
