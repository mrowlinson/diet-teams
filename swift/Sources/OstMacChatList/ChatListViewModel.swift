// ChatListViewModel.swift — loads chats via ostmac-core, owns sidebar state.
import Combine
import Foundation
import OstMacCore

/// Sidebar content state.
public enum ChatListState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty list in `chats`.
    case loaded
    /// Fetch succeeded with zero chats.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads the chat list off the main thread and publishes rows + selection.
///
/// Default fetcher calls `RustCore.chats` (blocking FFI + network) on a
/// detached task. Tests inject a mock fetcher. Conforms to ``ChatSelection``
/// so the conversation lane can share this instance as its selection source.
/// Also owns the leave/block flows (om-leave-block): leaving calls core
/// and drops the row locally on success; blocking records the user and
/// drops the row immediately. Neither path ever refetches the list.
@MainActor
public final class ChatListViewModel: ObservableObject, ChatSelection {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Fetcher = @Sendable (Int32) throws -> ChatsResponse
    /// Sync leave call (runs off-main). Throws `CoreCallError` on failure.
    public typealias Leaver = @Sendable (String) throws -> LeaveResponse

    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var chats: [ChatItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: ChatListState = .loading
    /// Sidebar selection (see ``ChatSelection``).
    @Published public var selectedChatID: String?
    /// Leave calls in flight (sidebar disables + spins these rows).
    @Published public private(set) var leavingIDs: Set<String> = []
    /// Last leave failure (sidebar error alert; nil when clear).
    @Published public private(set) var leaveError: String?
    /// Successful leaves this session (Diagnostics only).
    @Published public private(set) var leavesCompleted = 0
    /// Failed leave calls this session (Diagnostics only).
    @Published public private(set) var leaveFailures = 0

    public var selectedChat: ChatItem? {
        chats.first { $0.id == selectedChatID }
            ?? selectedChatID.flatMap(PinnedChats.row(for:))
    }

    /// Sidebar order: Mentions, Notifications, then recency. Pure
    /// projection over `chats` (which stays real-chats-only,
    /// recency-ordered); every ingest/filter/restart path re-derives it,
    /// so the pin invariant holds without a stored copy that could drift.
    public var displayChats: [ChatItem] {
        PinnedChats.sorted(chats)
    }

    /// Shared blocked-user list (Settings + Diagnostics read this same
    /// instance; the app passes its persistent one). Default is
    /// memory-only so tests and previews never touch real defaults.
    public let blocked: BlockedStore

    /// Fired with the chat id after a row leaves locally (leave success
    /// or block). The app clears per-chat satellite state here (unread,
    /// mention flags) — never a list refresh.
    public var onLocalRemove: ((String) -> Void)?

    private let fetcher: Fetcher
    private let leaver: Leaver

    public init(
        fetcher: @escaping Fetcher = { try RustCore.chats(limit: $0) },
        leaver: @escaping Leaver = { try RustCore.leaveChat(chatID: $0) },
        blocked: BlockedStore = BlockedStore(defaults: nil)
    ) {
        self.fetcher = fetcher
        self.leaver = leaver
        self.blocked = blocked
    }

    /// Fetch the list. Drops the selection when its chat is gone.
    /// Blocked threads are filtered before publish (they never render).
    public func load(limit: Int32 = 50) async {
        state = .loading
        let fetcher = fetcher
        do {
            let response = try await Task.detached {
                try fetcher(limit)
            }.value
            let visible = blocked.filtered(response.chats)
            chats = visible
            state = visible.isEmpty ? .empty : .loaded
            if let sel = selectedChatID,
               !PinnedChats.isSynthetic(sel),
               !visible.contains(where: { $0.id == sel })
            {
                selectedChatID = nil
            }
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Leave one group chat: call core, then drop the row locally and
    /// migrate the selection (see ``LeaveSelection``). No refetch —
    /// the server row simply stops arriving. Unknown, synthetic, blank,
    /// or already-leaving ids are a no-op. Failure keeps the row and
    /// publishes `leaveError` (sidebar alert offers Retry).
    public func leave(chatID: String) async {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !PinnedChats.isSynthetic(id) else { return }
        guard chats.contains(where: { $0.id == id }) else { return }
        guard !leavingIDs.contains(id) else { return }
        leavingIDs.insert(id)
        leaveError = nil
        let leaver = leaver
        do {
            _ = try await Task.detached { try leaver(id) }.value
            leavingIDs.remove(id)
            leavesCompleted += 1
            removeLocally(chatID: id)
        } catch {
            leavingIDs.remove(id)
            leaveFailures += 1
            leaveError = Self.message(for: error)
        }
    }

    /// Block one 1:1 thread's user: record the block, then drop the row
    /// locally and migrate the selection. Synchronous and local-only
    /// (Teams exposes no block endpoint — enforcement is the hidden row
    /// plus the app's notify/unread/mention gates). Unknown, synthetic,
    /// or blank ids are a no-op.
    public func block(chatID: String) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !PinnedChats.isSynthetic(id) else { return }
        guard let row = chats.first(where: { $0.id == id }) else { return }
        blocked.block(chatID: id, name: row.name)
        removeLocally(chatID: id)
    }

    /// Dismiss the leave error (sidebar alert Cancel).
    public func clearLeaveError() {
        leaveError = nil
    }

    /// Drop one row without refetching; migrate a stranded selection to
    /// its neighbor (never the dead thread, never a blind first-row
    /// jump for untouched selections). Unknown ids are a no-op.
    public func removeLocally(chatID: String) {
        guard chats.contains(where: { $0.id == chatID }) else { return }
        let next = LeaveSelection.fallback(
            removedID: chatID, chats: chats, selectedID: selectedChatID)
        chats.removeAll { $0.id == chatID }
        selectedChatID = next
        onLocalRemove?(chatID)
    }

    /// Fire-and-forget reload (error-state Retry, resync, sign-in).
    public func refresh(limit: Int32 = 50) {
        Task { await load(limit: limit) }
    }

    /// Realtime feed: only user text bubbles a row to the top. Beacons,
    /// blobs, cards, and reaction-only patches are a no-op (no reorder,
    /// no publish); bots, system notices, edits, and meeting cards update
    /// the preview in place. Unknown chat ids are a no-op (a resync
    /// refetch picks up new chats).
    public func ingest(realtime message: RealtimeMessage) {
        let next = Self.ingested(message, into: chats)
        guard next != chats else { return }
        chats = next
    }

    /// Burst ingest: fold a poll burst with ONE publish. Chats touched
    /// only by skips keep their exact rows (stable identity, no List diff).
    public func ingest(batch: [RealtimeMessage]) {
        let next = Self.ingested(batch, into: chats)
        guard next != chats else { return }
        chats = next
    }

    /// Pure ingest: user text bubbles to top; bots/system/edits/cards stay
    /// in place; beacons/blobs/unknown ids leave the list unchanged.
    public nonisolated static func ingested(_ message: RealtimeMessage, into list: [ChatItem]) -> [ChatItem] {
        guard let i = list.firstIndex(where: { $0.id == message.chatID }) else { return list }
        let old = list[i]
        let outcome = SidebarIngest.decide(message: message, chatName: old.name)
        guard outcome != .skip else { return list }
        let isMeeting = MeetingSignal.isMeetingThread(old.chatId)
        // Meeting previews are last user text: mine the human card lines;
        // nothing human → keep the row. Image-only keeps its sender line.
        let preview: String
        if isMeeting, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let human = SidebarIngest.humanLines(message.text) else { return list }
            preview = human
        } else {
            preview = message.text
        }
        // In-place rows with no attributable author (system notices,
        // mined meeting cards) show the bare text, never a "?:" prefix.
        let sender: String?
        if outcome == .refresh,
           (SidebarIngest.isSystem(message)
               || (isMeeting && SidebarIngest.isMixedCard(message.text))),
           MeetingSignal.isUnknownSender(message.sender)
        {
            sender = nil
        } else {
            sender = message.sender
        }
        let updated = ChatItem(
            chatId: old.chatId, name: old.name, is_group: old.is_group,
            last_message_time: message.time,
            last_message_sender: sender,
            last_message_preview: preview)
        if outcome == .refresh {
            var out = list
            out[i] = updated
            return out
        }
        var out = list
        out.remove(at: i)
        out.insert(updated, at: 0)
        return out
    }

    /// Pure batch fold: sequential ingest, order resolved once by the final
    /// fold (the last user-active chat ends on top).
    public nonisolated static func ingested(_ messages: [RealtimeMessage], into list: [ChatItem]) -> [ChatItem] {
        messages.reduce(list) { Self.ingested($1, into: $0) }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
