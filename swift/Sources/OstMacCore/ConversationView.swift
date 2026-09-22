// ConversationView.swift — om-conv lane: SwiftUI chat window for one chat.
// Host sets up the store (open(chatID:) or .demo()), this view renders
// bubbles (sender + time + text) plus a send box. Realtime edits arrive
// via store.ingest and update bubbles in place — no view changes needed.
import SwiftUI

public struct ConversationView: View {
    @ObservedObject public var store: ConversationStore
    @State private var draft = ""
    @FocusState private var boxFocused: Bool

    public init(store: ConversationStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if store.messages.isEmpty, !store.loading {
                            Text("No messages yet.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(store.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.messages.count) {
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy)
                    store.openIfNeeded()
                }
            }
            Divider()
            sendBox
        }
        .frame(minWidth: 380, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = store.messages.last else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isOwn { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(message.sender) · \(message.displayTime)")
                    .font(.caption)
                    .foregroundStyle(message.isOwn ? .white.opacity(0.85) : .secondary)
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(message.isOwn ? Color.blue : Color.gray.opacity(0.15))
            .foregroundStyle(message.isOwn ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if !message.isOwn { Spacer(minLength: 48) }
        }
    }
}
