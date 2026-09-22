// ConversationView.swift — om-conv/om-convrich: SwiftUI chat window.
// Rich bubbles (mentions, code spans, links), day separators, scroll-up
// load-more paging, edited markers, failed-send retry.
import SwiftUI

public struct ConversationView: View {
    @ObservedObject public var store: ConversationStore
    @ObservedObject private var presence: PresenceStore
    /// False for 1:1 chats (header shows the chatmate dot).
    private let isGroup: Bool
    @State private var draft = ""
    @State private var lastSeenID: String?
    @FocusState private var boxFocused: Bool

    public init(store: ConversationStore, presence: PresenceStore = PresenceStore(), isGroup: Bool = true) {
        self.store = store
        self.presence = presence
        self.isGroup = isGroup
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        loadMoreRow
                        if store.messages.isEmpty, !store.loading {
                            Text("No messages yet.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(sections, id: \.key) { section in
                            DaySeparator(label: section.label)
                            ForEach(section.messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    failed: store.failedIDs.contains(msg.id),
                                    onRetry: { _ = store.retry(id: msg.id) }
                                )
                                .id(msg.id)
                            }
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.messages.count) {
                    scrollOnNew(proxy)
                }
                .onAppear {
                    store.openIfNeeded()
                    scrollToBottom(proxy, animated: false)
                    lastSeenID = store.messages.last?.id
                }
            }
            Divider()
            sendBox
        }
        .frame(minWidth: 380, minHeight: 480)
    }

    private var sections: [MessageRender.DaySection] {
        MessageRender.daySections(store.messages)
    }

    private var loadMoreRow: some View {
        Group {
            if store.loadingMore {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            } else if store.canLoadMore {
                Button("Load older messages") { store.loadMore() }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .onAppear { store.loadMore() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if !isGroup, let id = store.chatID {
                    PresenceDot(availability: presence.availabilityForChat(id))
                }
                Text(store.chatName ?? store.chatID ?? "Conversation")
                    .font(.headline)
                    .lineLimit(1)
                if store.isDemo {
                    Text("DEMO")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Text("\(store.messages.count)")
                    .font(.caption).monospaced()
                    .foregroundStyle(.secondary)
            }
            if let err = store.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var sendBox: some View {
        HStack {
            TextField("Message", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($boxFocused)
                .onSubmit { submit() }
            Button("Send") { submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .onAppear { boxFocused = true }
    }

    private func submit() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        store.send(text: body)
    }

    /// Auto-scroll only when the tail actually advanced (new message), never
    /// for top-prepended history pages (count grows but last id is stable).
    private func scrollOnNew(_ proxy: ScrollViewProxy) {
        let current = store.messages.last?.id
        guard current != lastSeenID else { return }
        lastSeenID = current
        scrollToBottom(proxy)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = store.messages.last else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            } else {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

struct DaySeparator: View {
    let label: String

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.12))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.top, 4)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var failed: Bool = false
    var onRetry: () -> Void = {}

    var body: some View {
        HStack {
            if message.isOwn { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(message.sender) · \(message.displayTime)")
                        .font(.caption)
                        .foregroundStyle(message.isOwn ? .white.opacity(0.85) : .secondary)
                    if message.edited {
                        Text("(edited)")
                            .font(.caption2)
                            .italic()
                            .foregroundStyle(message.isOwn ? .white.opacity(0.7) : .secondary)
                    }
                }
                Text(MessageRender.attributedBody(for: message))
                    .font(.body)
                    .tint(message.isOwn ? .white : .accentColor)
                    .textSelection(.enabled)
                if failed {
                    HStack(spacing: 6) {
                        Text("Not delivered")
                            .font(.caption)
                            .foregroundStyle(message.isOwn ? .white : .red)
                        Button("Retry", action: onRetry)
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(10)
            .background(message.isOwn ? Color.blue : Color.gray.opacity(0.15))
            .foregroundStyle(message.isOwn ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(failed ? 0.85 : 1)
            if !message.isOwn { Spacer(minLength: 48) }
        }
    }
}
