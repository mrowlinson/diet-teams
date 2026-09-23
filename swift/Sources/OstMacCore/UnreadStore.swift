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
// Threading: @MainActor (ObservableObject for the sidebar + NSApp dock).
// The dock sink is injectable for tests (FakeDockBadge records labels).
import AppKit
import Foundation

/// Dock badge sink: the real dock tile or an in-memory fake.
public protocol DockBadging: Sendable {
    func setBadge(_ label: String?)
}

/// Live sink over NSApp.dockTile. Hops to the main thread (AppKit).
public final class SystemDockBadge: DockBadging, @unchecked Sendable {
    public init() {}

    public func setBadge(_ label: String?) {
        let value = label ?? ""
        if Thread.isMainThread {
            NSApp.dockTile.badgeLabel = value
        } else {
            DispatchQueue.main.sync { NSApp.dockTile.badgeLabel = value }
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

    private let dock: any DockBadging

    /// Nonisolated so views can take a default `UnreadStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(dock: (any DockBadging)? = nil) {
        self.dock = dock ?? SystemDockBadge()
    }

    /// Total unread across chats (the dock number).
    public var total: Int {
        counts.values.reduce(0, +)
    }

    /// Dock label for the current total: nil at zero (clears the tile).
    public var badgeLabel: String? {
        Self.badgeLabel(forTotal: total)
    }

    /// Pure label: nil at zero, else the decimal total.
    nonisolated public static func badgeLabel(forTotal total: Int) -> String? {
        total > 0 ? "\(total)" : nil
    }

    /// Pure accrual gate: notify counts unless the chat is already open
    /// (visible bubbles) or the id is blank. Every skip never counts.
    nonisolated public static func shouldCount(
        decision: ChatFilter.Decision, chatID: String, openChatID: String?
    ) -> Bool {
        guard case .notify = decision else { return false }
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let open = openChatID, open == chatID { return false }
        return true
    }

    /// Accrue one rules decision for a chat. Skips and open-chat
    /// notifies are no-ops (no dock write).
    public func ingest(
        decision: ChatFilter.Decision, chatID: String, openChatID: String?
    ) {
        guard Self.shouldCount(decision: decision, chatID: chatID, openChatID: openChatID) else { return }
        counts[chatID, default: 0] += 1
        syncDock()
    }

    /// Convenience: decide via ChatFilter (stateful meeting window),
    /// accrue, and return the decision so the caller reuses it for the
    /// banner (one decide per event — never double-claim the window).
    @discardableResult
    public func ingest(
        message: RealtimeMessage, chatDisplayName: String,
        ownerMRI: String?, rules: RulesConfig,
        meetingDedup: inout MeetingStartDedup, now: Date,
        openChatID: String?, teamsMutedChatIDs: Set<String> = []
    ) -> ChatFilter.Decision {
        let decision = ChatFilter.decide(
            message: message, chatDisplayName: chatDisplayName,
            ownerMRI: ownerMRI, rules: rules,
            meetingDedup: &meetingDedup, now: now,
            teamsMutedChatIDs: teamsMutedChatIDs)
        ingest(decision: decision, chatID: message.chatID, openChatID: openChatID)
        return decision
    }

    /// Unread for one chat (0 when absent).
    public func count(for chatID: String) -> Int {
        counts[chatID] ?? 0
    }

    /// Opening a chat marks it read (drops its count, syncs the dock).
    /// Unknown ids are a no-op (no dock write).
    public func markRead(chatID: String) {
        guard counts.removeValue(forKey: chatID) != nil else { return }
        syncDock()
    }

    /// Clear every chat (sign-out). Empty is a no-op (no dock write).
    public func markAllRead() {
        guard !counts.isEmpty else { return }
        counts.removeAll()
        syncDock()
    }

    private func syncDock() {
        dock.setBadge(badgeLabel)
    }
}
