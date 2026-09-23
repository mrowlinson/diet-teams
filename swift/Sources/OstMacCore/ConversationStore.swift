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
    @Published public private(set) var loadingMore = false
    @Published public private(set) var error: String?
    @Published public private(set) var didLoad = false
    @Published public private(set) var failedIDs: Set<String> = []
    /// Armed quote-reply target (om-replies): set by the bubble Reply
    /// action, cleared by send/cancel/chat-switch. `send(text:)` posts
    /// through the reply path while set.
    @Published public private(set) var replyTarget: ChatMessage?
    public private(set) var chatID: String?
    public private(set) var chatName: String?
    public private(set) var isDemo = false
    /// Own sender name (whoami display_name); nil until resolved or in demo.
    /// Stamps `isOwn` on history, pages, and realtime ingests.
    public private(set) var ownDisplayName: String?
    private var openGeneration = 0

    /// Opaque cursor for the next older page; nil = end of history.
    public private(set) var pageToken: String?

    public init() {}

    /// Open a chat: fetch newest history page via core, replace messages.
    /// Stale completions are dropped, so fast chat-switching always
    /// lands on the newest selection.
    public func open(chatID: String, chatName: String? = nil, limit: Int32 = 50) {
        self.chatID = chatID
        if let n = chatName { self.chatName = n }
        loading = true
        error = nil
        replyTarget = nil
        openGeneration += 1
        let gen = openGeneration
        pageToken = nil
        Task {
            // Best-effort identity (core-cached after first call); a stale
            // stored name still stamps when refresh fails.
            let own: String? = try? await Task.detached {
                try RustCore.whoami().display_name
            }.value
            let fetched: Result<MessagesResponse, Error>
            do {
                let resp = try await Task.detached {
                    try RustCore.messages(chatID: chatID, limit: limit)
                }.value
                fetched = .success(resp)
            } catch {
                fetched = .failure(error)
            }
            guard gen == openGeneration else { return } // superseded
            loading = false
            didLoad = true
            switch fetched {
            case let .success(resp):
                if let own { ownDisplayName = own }
                messages = Self.stampOwnership(resp.messages, ownName: ownDisplayName)
                pageToken = resp.page_token
            case let .failure(e): error = String(describing: e)
            }
        }
    }

    /// Adopt an identity without core (tests, sign-in completion).
    public func adoptIdentity(displayName: String) {
        ownDisplayName = displayName
        messages = Self.stampOwnership(messages, ownName: ownDisplayName)
    }

    /// Drop identity after sign-out; existing bubbles keep their flags.
    public func clearIdentity() {
        ownDisplayName = nil
    }

    /// Pure ownership stamp: `isOwn` iff `sender` equals the own name.
    /// Nil name leaves every flag false (matches core's unsigned state).
    public static func stampOwnership(_ list: [ChatMessage], ownName: String?) -> [ChatMessage] {
        guard let own = ownName else {
            return list.map { var m = $0; m.isOwn = false; return m }
        }
        return list.map { var m = $0; m.isOwn = (m.sender == own); return m }
    }

    /// True while an older page exists and no load is in flight.
    public var canLoadMore: Bool {
        !isDemo && !loading && !loadingMore && pageToken != nil
    }

    /// Prepend the next older history page (scroll-up load-more).
    /// No-op without a page token or while a load is in flight.
    public func loadMore(limit: Int32 = 50) {
        guard canLoadMore, let id = chatID, let tok = pageToken else { return }
        loadingMore = true
        Task {
            let fetched: Result<MessagesResponse, Error>
            do {
                let resp = try await Task.detached {
                    try RustCore.messagesPage(chatID: id, pageToken: tok, limit: limit)
                }.value
                fetched = .success(resp)
            } catch {
                fetched = .failure(error)
            }
            loadingMore = false
            switch fetched {
            case let .success(resp):
                messages = Self.prepend(
                    Self.stampOwnership(resp.messages, ownName: ownDisplayName), to: messages)
                pageToken = resp.page_token
            case let .failure(e): error = String(describing: e)
            }
        }
    }

    /// Pure prepend: older page first, existing ids win on overlap.
    public static func prepend(_ older: [ChatMessage], to list: [ChatMessage]) -> [ChatMessage] {
        let known = Set(list.map(\.id))
        return older.filter { !known.contains($0.id) } + list
    }

    /// View helper: open once when the host set chatID but never loaded.
    public func openIfNeeded(limit: Int32 = 50) {
        guard !isDemo, !loading, !didLoad, let id = chatID else { return }
        open(chatID: id, limit: limit)
    }

    /// Realtime feed: upsert by id (new appends, known edits in place).
    /// Stamps `isOwn` against the known identity first.
    public func ingest(_ message: ChatMessage) {
        var m = message
        m.isOwn = ownDisplayName.map { m.sender == $0 } ?? false
        messages = Self.upsert(m, into: messages)
    }

    /// Realtime edit carrying only new text; unknown id is a no-op.
    /// Marks the bubble edited.
    public func ingestEdited(id: String, content: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        guard messages[i].content != content else { return }
        messages[i].content = content
        messages[i].edited = true
    }

    /// Realtime feed: typed event → upsert by id (edits collapse onto
    /// the edited id, so bubbles update in place; unknown edit ids
    /// append, so nothing is lost). Callers filter by chat first via
    /// `RealtimeMessage.isFor(chatID:)`.
    public func ingest(realtime message: RealtimeMessage) {
        ingest(message.asChatMessage)
    }

    /// Demo mode: show canned messages for a chat (offline, no core).
    /// `failed` pre-marks bubbles failed (rich demo's failed own send).
    public func showDemo(
        chatID: String, chatName: String, messages: [ChatMessage],
        failed: Set<String> = []
    ) {
        self.chatID = chatID
        self.chatName = chatName
        self.messages = messages
        failedIDs = failed
        replyTarget = nil
        isDemo = true
        loading = false
        error = nil
        didLoad = true
    }

    /// Arm a quote reply to `message` (bubble Reply action / shot hook).
    /// Unknown ids still arm (the quote block carries the attribution),
    /// but the bubble quote preview needs the parent in `messages`.
    public func beginReply(to message: ChatMessage) {
        replyTarget = message
    }

    /// Disarm the pending reply (chip ✕ / after send / chat switch).
    public func cancelReply() {
        replyTarget = nil
    }

    /// Parent bubble for a reply's `reply_to` id, if still in history.
    /// Nil id or evicted parent → nil (caller shows the fallback quote).
    public func quotedParent(for message: ChatMessage) -> ChatMessage? {
        guard let parentID = message.reply_to else { return nil }
        return messages.first(where: { $0.id == parentID })
    }

    /// One-line quote preview: collapsed whitespace, 120 chars + `…`.
    /// Pure so the bubble, chip, and tests share it.
    public static func quotePreview(_ text: String, max: Int = 120) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > max else { return oneLine }
        let end = oneLine.index(oneLine.startIndex, offsetBy: max)
        return "\(oneLine[..<end])…"
    }

    /// Post via core; appends an optimistic own-bubble immediately.
    /// Demo mode appends locally without touching core.
    /// With `replyTarget` armed, posts through the reply path (quote
    /// block) and disarms; the optimistic bubble already shows the quote.
    /// Core failure marks the bubble failed (per-message state + retry).
    public func send(text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let parent = replyTarget
        replyTarget = nil
        if isDemo {
            messages.append(ChatMessage(
                id: "demo-local-\(messages.count + 1)",
                sender: "Me", timestamp: Self.nowISO(), content: body, isOwn: true,
                reply_to: parent?.id))
            return
        }
        guard let id = chatID else { return }
        let pendingID = "pending-\(UUID().uuidString)"
        messages.append(ChatMessage(
            id: pendingID,
            sender: "Me", timestamp: Self.nowISO(), content: body, isOwn: true,
            reply_to: parent?.id))
        Task {
            do {
                if let parent {
                    let p = parent
                    _ = try await Task.detached {
                        try RustCore.reply(
                            chatID: id, parentID: p.id,
                            parentSender: p.sender, parentText: p.content, text: body)
                    }.value
                } else {
                    _ = try await Task.detached {
                        try RustCore.send(chatID: id, text: body)
                    }.value
                }
            } catch {
                self.noteSendFailed(id: pendingID)
                self.error = "send failed: \(error)"
            }
        }
    }

    /// Record a failed optimistic send (test seam + retry bookkeeping).
    func noteSendFailed(id: String) {
        failedIDs.insert(id)
    }

    /// Retry a failed send: clears the flag, re-posts the bubble's text.
    /// No-op for unknown ids. Returns the text re-sent, if any.
    @discardableResult
    public func retry(id: String) -> String? {
        guard failedIDs.contains(id),
              let msg = messages.first(where: { $0.id == id })
        else { return nil }
        failedIDs.remove(id)
        send(text: msg.content)
        return msg.content
    }

    /// Pure upsert: new id appends; known id rewrites content in place and
    /// marks the bubble edited.
    public static func upsert(_ message: ChatMessage, into list: [ChatMessage]) -> [ChatMessage] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == message.id }) {
            // Same-content redelivery is not an edit: no marker.
            if out[i].content != message.content {
                out[i].content = message.content
                out[i].edited = true
            }
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

    public nonisolated static let demoMessages: [ChatMessage] = [
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

    // MARK: - Rich demo (om-convrich: mentions, code, edits, failure, 2 days)

    /// Canned store exercising every rich state: day separators (yesterday +
    /// today), @mentions, code blocks, backticks, a link, an edited bubble,
    /// and one failed own send with retry. Timestamps float off now so the
    /// separators always read Yesterday/Today. Offline, no sign-in.
    public static func demoRich() -> ConversationStore {
        let s = ConversationStore()
        s.isDemo = true
        s.chatID = "demo-rich"
        s.chatName = "Demo — Rich Conversation"
        s.messages = richDemoMessages()
        s.didLoad = true
        s.failedIDs = ["rich-fail"]
        return s
    }

    public nonisolated static func richDemoMessages(now: Date = Date()) -> [ChatMessage] {
        func iso(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: d)
        }
        func at(dayOffset: Int, h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            let base = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        }
        return [
            ChatMessage(
                id: "rich-1", sender: "Priya Nair",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 2)),
                content: "Kicking off the richness pass. @Tom Becker can you own code blocks?",
                raw: "<p>Kicking off the richness pass. <at id=\"8:t\">@Tom Becker</at> can you own code blocks?</p>"),
            ChatMessage(
                id: "rich-2", sender: "Tom Becker",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 5)),
                content: "On it. Shipped the span miner — see the deploy notes: https://example.com/deploys/42",
                raw: "<p>On it. Shipped the span miner — see the deploy notes: <a href=\"https://example.com/deploys/42\">https://example.com/deploys/42</a></p>"),
            ChatMessage(
                id: "rich-3", sender: "Tom Becker",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 7)),
                content: "Usage: run `ostmac conv --rich` then paste the snippet\nlet x = render(msg) // one line",
                raw: "<p>Usage: run `ostmac conv --rich` then paste the snippet</p><pre>let x = render(msg) // one line</pre>"),
            ChatMessage(
                id: "rich-4", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 1)),
                content: "Morning — paging works, backwardLink chains with zero overlap.",
                isOwn: true),
            ChatMessage(
                id: "rich-5", sender: "Priya Nair",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 4)),
                content: "Nice. @Me please double-check the edited marker on this bubble.",
                raw: "<p>Nice. <at id=\"8:me\">@Me</at> please double-check the edited marker on this bubble.</p>",
                edited: true),
            ChatMessage(
                id: "rich-6", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 6)),
                content: "Confirmed — edits stay in place, marker shows. `MessageRender` handles the spans.",
                isOwn: true),
            ChatMessage(
                id: "rich-fail", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 8)),
                content: "This send failed (airplane mode?) — retry from the bubble.",
                isOwn: true),
        ]
    }
}
