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
@MainActor
public final class ChatListViewModel: ObservableObject, ChatSelection {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Fetcher = @Sendable (Int32) throws -> ChatsResponse

    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var chats: [ChatItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: ChatListState = .loading
    /// Sidebar selection (see ``ChatSelection``).
    @Published public var selectedChatID: String?

    public var selectedChat: ChatItem? {
        chats.first { $0.id == selectedChatID }
            ?? selectedChatID.flatMap(PinnedChats.row(for:))
    }

    /// Sidebar order: Mentions, Notifications, user pins (pin-time
    /// order), then recency. Pure projection over `chats` (which stays
    /// real-chats-only, recency-ordered) plus the persisted pin list;
    /// every ingest/filter/restart path re-derives it, so the pin
    /// invariant holds without a stored copy that could drift.
    public var displayChats: [ChatItem] {
        PinnedChats.sorted(chats, pins: pins.orderedIDs)
    }

    /// User-pinned chats (persisted; the sidebar's Pin/Unpin context
    /// menu acts through `pin(_:)`/`unpin(_:)` below).
    public let pins: UserPinStore

    private let fetcher: Fetcher
    private var cancellables = Set<AnyCancellable>()

    public init(
        fetcher: @escaping Fetcher = { try RustCore.chats(limit: $0) },
        pins: UserPinStore = UserPinStore()
    ) {
        self.fetcher = fetcher
        self.pins = pins
        self.pins.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// True when the chat is user-pinned (context-menu state).
    public func isPinned(_ id: String) -> Bool {
        pins.isPinned(id)
    }

    /// Pin a chat (no-op for synthetic/blank/duplicate ids — the
    /// store refuses them; the list is never refetched here).
    public func pin(_ id: String) {
        pins.pin(id)
    }

    /// Unpin a chat (unknown ids are a no-op; the row returns to
    /// recency order on the next `displayChats` read).
    public func unpin(_ id: String) {
        pins.unpin(id)
    }

    /// Fetch the list. Drops the selection when its chat is gone.
    public func load(limit: Int32 = 50) async {
        state = .loading
        let fetcher = fetcher
        do {
            let response = try await Task.detached {
                try fetcher(limit)
            }.value
            chats = response.chats
            state = response.chats.isEmpty ? .empty : .loaded
            if let sel = selectedChatID,
               !PinnedChats.isSynthetic(sel),
               !response.chats.contains(where: { $0.id == sel })
            {
                selectedChatID = nil
            }
        } catch {
            state = .error(Self.message(for: error))
        }
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
