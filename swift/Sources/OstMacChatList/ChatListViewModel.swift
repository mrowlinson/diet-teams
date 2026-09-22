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
    }

    private let fetcher: Fetcher

    public init(fetcher: @escaping Fetcher = { try RustCore.chats(limit: $0) }) {
        self.fetcher = fetcher
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
               !response.chats.contains(where: { $0.id == sel })
            {
                selectedChatID = nil
            }
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (toolbar button, pull-to-refresh).
    public func refresh(limit: Int32 = 50) {
        Task { await load(limit: limit) }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
