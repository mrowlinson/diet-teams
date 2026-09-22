// ConversationStore.swift — om-conv lane: state for one open chat.
//
// INPUT API (what the chat-list and realtime lanes drive):
//   store.open(chatID:chatName:) — load full history via core (replaces messages)
//   store.ingest(_ message:)      — upsert one realtime ChatMessage by id:
//                                  new id appends, known id updates content
//                                  in place (edit). THE realtime feed point.
//   store.ingestEdited(id:content:) — edit event carrying only new text
//   store.send(text:)             — post via core, optimistic own-bubble
// Shared model: ChatMessage (Models.swift) — history, send-echo, and
// realtime all use it; `id` is the match key for edits.
import Foundation

@MainActor
public final class ConversationStore: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var didLoad = false
    public private(set) var chatID: String?
    public private(set) var chatName: String?
    public private(set) var isDemo = false

    public init() {}

    /// Open a chat: fetch full history via core, replace messages.
    public func open(chatID: String, chatName: String? = nil, limit: Int32 = 50) {
        self.chatID = chatID
        if let n = chatName { self.chatName = n }
        loading = true
        error = nil
        Task {
            let fetched: Result<[ChatMessage], Error>
            do {
                let resp = try await Task.detached {
                    try RustCore.messages(chatID: chatID, limit: limit)
                }.value
                fetched = .success(resp.messages)
            } catch {
                fetched = .failure(error)
            }
            loading = false
            didLoad = true
            switch fetched {
            case let .success(msgs): messages = msgs
            case let .failure(e): error = String(describing: e)
            }
        }
    }

    /// View helper: open once when the host set chatID but never loaded.
    public func openIfNeeded(limit: Int32 = 50) {
        guard !isDemo, !loading, !didLoad, let id = chatID else { return }
        open(chatID: id, limit: limit)
    }

    /// Realtime feed: upsert by id (new appends, known edits in place).
    public func ingest(_ message: ChatMessage) {
        messages = Self.upsert(message, into: messages)
    }

    /// Realtime edit carrying only new text; unknown id is a no-op.
    public func ingestEdited(id: String, content: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].content = content
    }

    /// Post via core; appends an optimistic own-bubble immediately.
    /// Demo mode appends locally without touching core.
    public func send(text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if isDemo {
            messages.append(ChatMessage(
                id: "demo-local-\(messages.count + 1)",
                sender: "Me", timestamp: Self.nowISO(), content: body, isOwn: true))
            return
        }
        guard let id = chatID else { return }
        messages.append(ChatMessage(
            id: "pending-\(UUID().uuidString)",
            sender: "Me", timestamp: Self.nowISO(), content: body, isOwn: true))
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.send(chatID: id, text: body)
                }.value
            } catch {
                self.error = "send failed: \(error)"
            }
        }
    }

    /// Pure upsert: new id appends; known id rewrites content in place.
    public static func upsert(_ message: ChatMessage, into list: [ChatMessage]) -> [ChatMessage] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == message.id }) {
            out[i].content = message.content
        } else {
            out.append(message)
        }
        return out
    }

    static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    // MARK: - Demo mode (canned messages for offline shots)

    public static func demo() -> ConversationStore {
        let s = ConversationStore()
        s.isDemo = true
        s.chatID = "demo"
        s.chatName = "Demo — Design Sync"
        s.messages = demoMessages
        s.didLoad = true
        return s
    }

    public static let demoMessages: [ChatMessage] = [
        ChatMessage(
            id: "demo-1", sender: "Priya Nair",
            timestamp: "2026-09-22T09:02:11Z",
            content: "Morning! Design sync in 10. Today: onboarding flow + empty states."),
        ChatMessage(
            id: "demo-2", sender: "Tom Becker",
            timestamp: "2026-09-22T09:04:47Z",
            content: "Pushed new mocks for the chat window last night — bubbles, timestamps, the works."),
        ChatMessage(
            id: "demo-3", sender: "Priya Nair",
            timestamp: "2026-09-22T09:06:02Z",
            content: "Love the bubble alignment. Can we keep edited messages in place instead of re-sorting?"),
        ChatMessage(
            id: "demo-4", sender: "Me",
            timestamp: "2026-09-22T09:07:30Z",
            content: "Yes — edits update the bubble in place, keyed by message id.", isOwn: true),
        ChatMessage(
            id: "demo-5", sender: "Tom Becker",
            timestamp: "2026-09-22T09:09:15Z",
            content: "And the send box posts straight through core? No drafts lost on network hiccups?"),
        ChatMessage(
            id: "demo-6", sender: "Me",
            timestamp: "2026-09-22T09:10:41Z",
            content: "Optimistic bubble first, then the core send call confirms. Failures surface inline.", isOwn: true),
        ChatMessage(
            id: "demo-7", sender: "Priya Nair",
            timestamp: "2026-09-22T09:12:05Z",
            content: "Ship it. I'll take screenshots for the review deck."),
    ]
}
