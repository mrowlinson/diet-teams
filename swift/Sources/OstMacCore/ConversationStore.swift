// ConversationStore.swift — om-conv lane: state for one open chat.
//
// INPUT API (what the chat-list and realtime lanes drive):
//   store.open(chatID:chatName:) — load last-24h window via core (replaces messages)
//   store.ingest(_ message:)      — upsert one realtime ChatMessage by id:
//                                  new id appends, known id updates content
//                                  in place (edit). THE realtime feed point.
//   store.ingestEdited(id:content:) — edit event carrying only new text
//   store.send(text:)             — post via core, optimistic own-bubble
//   store.toggleReaction(messageID:emoji:) — picker tap: add/remove one
//                                  emoji, optimistic, reverts on failure
//   store.applyReactions(id:reactions:) — realtime counts patch (no-op
//                                  on unknown ids, never appends)
//   store.edit(messageID:text:)   — edit own bubble via core (optimistic)
//   store.deleteMessage(id:)      — delete own bubble via core (optimistic)
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
    /// Header title: the resolved chat name, else the generic label —
    /// never the raw chat id (om-chatnames).
    public var headerTitle: String {
        if let n = chatName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return "Conversation"
    }
    public private(set) var isDemo = false
    /// Own sender name (whoami display_name); nil until resolved or in demo.
    /// Stamps `isOwn` on history, pages, and realtime ingests.
    public private(set) var ownDisplayName: String?
    private var openGeneration = 0

    /// Opaque cursor for the next older page; nil = end of history.
    public private(set) var pageToken: String?

    public init() {}

    // MARK: - History window (om-history)

    /// Initial load covers the last 24h: `open` pages back until the
    /// oldest message is older than the window (or the page cap / end
    /// of history hits). The server ignores `startTime=` (OSTMAC-PATCHES
    /// #7), so the window is enforced client-side over the page_token
    /// chain — no core time params needed.
    public nonisolated static let historyWindowHours: Double = 24
    /// Fetch bounds: one open / day-load never fires more page fetches
    /// than this, so long threads can't churn the view unboundedly.
    public nonisolated static let openMaxPages = 6
    public nonisolated static let dayLoadMaxPages = 4

    /// Tolerant ISO8601 parse for server stamps (fractional
    /// "…T12:53:06.9690000Z" and plain "…T12:53:06Z"). Nil for
    /// garbage/empty (callers stop paging — never spin on it).
    public static func messageDate(_ iso: String) -> Date? {
        let t = iso.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t) { return d }
        // Last resort: "yyyy-MM-dd'T'HH:mm:ss" prefix in UTC.
        guard t.count >= 19 else { return nil }
        let g = DateFormatter()
        g.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        g.timeZone = TimeZone(secondsFromGMT: 0)
        g.locale = Locale(identifier: "en_US_POSIX")
        return g.date(from: String(t.prefix(19)))
    }

    /// True once the loaded slice reaches past the window: oldest
    /// message older than `hours`, or its stamp unparseable (can't
    /// window garbage — stop after the current page). Empty keeps
    /// paging (blank pages cover nothing).
    public static func windowCovered(
        _ messages: [ChatMessage], now: Date = Date(), hours: Double = historyWindowHours
    ) -> Bool {
        guard let oldest = messages.first else { return false }
        guard let d = messageDate(oldest.timestamp) else { return true }
        return d <= now.addingTimeInterval(-hours * 3600)
    }

    /// True once a day-load chunk crossed into an earlier calendar day
    /// than it started on (`startDayKey` = dayKey of the oldest message
    /// before the chunk). Empty never counts as crossed.
    public static func dayChunkDone(startDayKey: String, messages: [ChatMessage]) -> Bool {
        guard let oldest = messages.first else { return false }
        return MessageRender.dayKey(oldest.timestamp) != startDayKey
    }

    /// Open a chat: fetch the last-24h window via core (newest page,
    /// published immediately, then older pages until the window is
    /// covered), replace messages. Stale completions are dropped, so
    /// fast chat-switching always lands on the newest selection. The
    /// previous thread is cleared up front: a failed open shows the
    /// error with retry, never stale bubbles under a new name.
    public func open(chatID: String, chatName: String? = nil, limit: Int32 = 50) {
        self.chatID = chatID
        if let n = chatName { self.chatName = n }
        messages = []
        pageToken = nil
        loading = true
        loadingMore = false
        error = nil
        replyTarget = nil
        openGeneration += 1
        let gen = openGeneration
        Task {
            // Best-effort identity (core-cached after first call); a stale
            // stored name still stamps when refresh fails.
            let own: String? = try? await Task.detached {
                try RustCore.whoami().display_name
            }.value
            guard gen == self.openGeneration else { return } // superseded
            if let own { self.ownDisplayName = own }
            do {
                let resp = try await Task.detached {
                    try RustCore.messages(chatID: chatID, limit: limit)
                }.value
                guard gen == self.openGeneration else { return }
                self.messages = Self.stampOwnership(resp.messages, ownName: self.ownDisplayName)
                self.pageToken = resp.page_token
                self.didLoad = true
                // Chain older pages until the 24h window is covered.
                var pages = 1
                while gen == self.openGeneration,
                      self.pageToken != nil,
                      !Self.windowCovered(self.messages),
                      pages < Self.openMaxPages
                {
                    guard let tok = self.pageToken else { break }
                    do {
                        let next = try await Task.detached {
                            try RustCore.messagesPage(chatID: chatID, pageToken: tok, limit: limit)
                        }.value
                        guard gen == self.openGeneration else { return }
                        self.messages = Self.prepend(
                            Self.stampOwnership(next.messages, ownName: self.ownDisplayName),
                            to: self.messages)
                        self.pageToken = next.page_token
                        pages += 1
                    } catch {
                        guard gen == self.openGeneration else { return }
                        self.error = String(describing: error)
                        break
                    }
                }
                if gen == self.openGeneration { self.loading = false }
            } catch {
                guard gen == self.openGeneration else { return }
                self.loading = false
                self.didLoad = true
                self.error = String(describing: error)
            }
        }
    }

    /// Re-run `open` for the current chat (empty-state Try Again).
    /// No-op without a chat, or in demo mode (demo never hits core).
    public func retryOpen(limit: Int32 = 50) {
        guard !isDemo, let id = chatID else { return }
        open(chatID: id, limit: limit)
    }

    /// Shot hook: surface a canned fetch error in demo mode only.
    /// Live stores ignore it (real errors come from core).
    public func seedDemoError(_ message: String) {
        guard isDemo else { return }
        error = message
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

    /// Prepend one lazy day-chunk of older history (scroll-top load).
    /// Pages until the oldest message crosses into an earlier calendar
    /// day than the chunk started on (or the cap / end hits); at least
    /// one page is always fetched. Each page applies as it arrives, so
    /// a mid-chunk failure keeps partial progress with the error
    /// surfaced and the token still on the next page — tapping again
    /// retries. No-op without a page token or while a load is in
    /// flight. Explicit taps only: the view no longer auto-fires (the
    /// old onAppear chained the whole thread, because the spinner /
    /// button swap re-triggers it after every page).
    public func loadMore(limit: Int32 = 50) {
        guard canLoadMore, let id = chatID else { return }
        loadingMore = true
        error = nil
        let gen = openGeneration
        let startDay = MessageRender.dayKey(messages.first?.timestamp ?? "")
        Task {
            var pages = 0
            var lastError: Error?
            while pages < Self.dayLoadMaxPages, let tok = self.pageToken {
                do {
                    let resp = try await Task.detached {
                        try RustCore.messagesPage(chatID: id, pageToken: tok, limit: limit)
                    }.value
                    guard gen == self.openGeneration else { return } // superseded
                    self.messages = Self.prepend(
                        Self.stampOwnership(resp.messages, ownName: self.ownDisplayName),
                        to: self.messages)
                    self.pageToken = resp.page_token
                    pages += 1
                    if Self.dayChunkDone(startDayKey: startDay, messages: self.messages) { break }
                } catch {
                    guard gen == self.openGeneration else { return } // superseded
                    lastError = error
                    break
                }
            }
            guard gen == self.openGeneration else { return } // superseded
            self.loadingMore = false
            if let e = lastError { self.error = String(describing: e) }
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
    /// `RealtimeMessage.isFor(chatID:)`. Counts ride along: events
    /// carrying `reactions` patch the bubble's counts; reaction-only
    /// events (empty text) patch counts without touching the bubble.
    public func ingest(realtime message: RealtimeMessage) {
        let targetID: String
        if message.isEdit, let edited = message.editedID {
            targetID = edited
        } else {
            targetID = message.msgId
        }
        if message.text.isEmpty, let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
            return
        }
        ingest(message.asChatMessage)
        if let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
        }
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

    /// Last forward from this store (om-msgactions). Set in demo mode
    /// synchronously; in live mode on send success. Powers tests + shots.
    @Published public private(set) var lastForward: MessageActions.ForwardRecord?
    /// Destination chat of the last forward (demo preview + tests).
    @Published public private(set) var lastForwardDestName: String?

    /// Forward one bubble's text to another chat (om-msgactions). Reuses
    /// the plain send path (no new FFI): the destination bubble stamps
    /// its own sender/time. Demo mode records without touching core.
    /// Empty destination or empty body is a no-op.
    public func forward(_ message: ChatMessage, toChatID destChatID: String, destName: String? = nil) {
        let dest = destChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        let body = MessageActions.forwardBody(for: message)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isDemo {
            lastForward = MessageActions.ForwardRecord(messageID: message.id, destChatID: dest, body: body)
            lastForwardDestName = destName
            return
        }
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.send(chatID: dest, text: body)
                }.value
                self.lastForward = MessageActions.ForwardRecord(messageID: message.id, destChatID: dest, body: body)
                self.lastForwardDestName = destName
            } catch {
                self.error = "forward failed: \(error)"
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

    // MARK: - Reactions (om-reactions)

    /// Picker emoji in canonical order (mirrors core REACTION_EMOJI).
    public static let reactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "😠"]

    /// Toggle one emoji on a bubble: present → remove, absent → add.
    /// Optimistic (counts move now); demo mode stays local; live mode
    /// reverts on core failure. Unknown ids are a no-op.
    public func toggleReaction(messageID: String, emoji: String) {
        guard messages.contains(where: { $0.id == messageID }) else { return }
        guard Self.reactionEmojis.contains(emoji) else { return }
        let present = messages.first(where: { $0.id == messageID })?
            .reactions.contains(where: { $0.emoji == emoji }) ?? false
        if present {
            removeReaction(messageID: messageID, emoji: emoji)
        } else {
            react(messageID: messageID, emoji: emoji)
        }
    }

    /// Add one emoji reaction (optimistic). Unknown ids are a no-op.
    public func react(messageID: String, emoji: String) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard Self.reactionEmojis.contains(emoji) else { return }
        messages[i].reactions = Self.withReactionAdded(messages[i].reactions, emoji: emoji)
        if isDemo { return }
        guard let id = chatID else { return }
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.react(chatID: id, messageID: messageID, emoji: emoji)
                }.value
            } catch {
                self.revertReaction(messageID: messageID, emoji: emoji, added: true)
                self.error = "react failed: \(error)"
            }
        }
    }

    /// Edit an own bubble via core; optimistic in-place update, rollback on
    /// failure. Demo mode edits locally. Unknown id / empty text are no-ops.
    public func edit(messageID: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard messages[i].content != body else { return }
        if isDemo {
            messages = Self.applyingEdit(id: messageID, content: body, to: messages)
            return
        }
        guard let id = chatID else { return }
        let old = messages[i].content
        let wasEdited = messages[i].edited
        messages = Self.applyingEdit(id: messageID, content: body, to: messages)
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.edit(chatID: id, messageID: messageID, text: body)
                }.value
            } catch {
                // Roll back to the pre-edit text.
                if let j = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[j].content = old
                    self.messages[j].edited = wasEdited
                }
                self.error = "edit failed: \(error)"
            }
        }
    }

    /// Remove one emoji reaction (optimistic). Unknown ids are a no-op.
    public func removeReaction(messageID: String, emoji: String) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].reactions = Self.withReactionRemoved(messages[i].reactions, emoji: emoji)
        if isDemo { return }
        guard let id = chatID else { return }
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.removeReaction(chatID: id, messageID: messageID, emoji: emoji)
                }.value
            } catch {
                self.revertReaction(messageID: messageID, emoji: emoji, added: false)
                self.error = "react failed: \(error)"
            }
        }
    }

    /// Undo one optimistic reaction change after a core failure.
    private func revertReaction(messageID: String, emoji: String, added: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].reactions = added
            ? Self.withReactionRemoved(messages[i].reactions, emoji: emoji)
            : Self.withReactionAdded(messages[i].reactions, emoji: emoji)
    }

    /// Replace one bubble's counts (realtime patch, server truth).
    /// Unknown ids are a no-op — counts never conjure a bubble.
    public func applyReactions(id: String, reactions: [ReactionCount]) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].reactions = reactions
    }

    /// Pure add: bump the emoji bucket, or append it (picker order kept).
    public static func withReactionAdded(_ list: [ReactionCount], emoji: String) -> [ReactionCount] {
        var out = list
        if let i = out.firstIndex(where: { $0.emoji == emoji }) {
            out[i] = ReactionCount(emoji: emoji, count: out[i].count + 1)
        } else {
            out.append(ReactionCount(emoji: emoji, count: 1))
            let order = reactionEmojis
            out.sort { (order.firstIndex(of: $0.emoji) ?? Int.max) < (order.firstIndex(of: $1.emoji) ?? Int.max) }
        }
        return out
    }

    /// Pure remove: decrement the emoji bucket; drop it at zero.
    /// Missing emoji leaves the list untouched.
    public static func withReactionRemoved(_ list: [ReactionCount], emoji: String) -> [ReactionCount] {
        var out = list
        guard let i = out.firstIndex(where: { $0.emoji == emoji }) else { return out }
        if out[i].count > 1 {
            out[i] = ReactionCount(emoji: emoji, count: out[i].count - 1)
        } else {
            out.remove(at: i)
        }
        return out
    }

    /// Delete an own bubble via core; optimistic removal, restore on failure.
    /// Demo mode deletes locally. Unknown id is a no-op.
    public func deleteMessage(id: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        if isDemo {
            messages = Self.removing(id: id, from: messages)
            return
        }
        guard let chat = chatID else { return }
        let removed = messages[i]
        messages = Self.removing(id: id, from: messages)
        failedIDs.remove(id)
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.deleteMessage(chatID: chat, messageID: id)
                }.value
            } catch {
                // Restore at the original index (clamped to the tail).
                var cur = self.messages
                cur.insert(removed, at: min(i, cur.count))
                self.messages = cur
                self.error = "delete failed: \(error)"
            }
        }
    }

    /// Pure edit: rewrite content in place + mark edited; unknown id unchanged.
    public static func applyingEdit(id: String, content: String, to list: [ChatMessage]) -> [ChatMessage] {
        var out = list
        guard let i = out.firstIndex(where: { $0.id == id }) else { return out }
        out[i].content = content
        out[i].edited = true
        return out
    }

    /// Pure delete: drop the bubble; unknown id unchanged.
    public static func removing(id: String, from list: [ChatMessage]) -> [ChatMessage] {
        list.filter { $0.id != id }
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
