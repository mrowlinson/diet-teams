// ConversationView.swift — om-conv/om-convrich/om-shared/om-notes/om-cmdk/om-catchup: SwiftUI chat window.
// Rich bubbles (mentions, code spans, links), day separators, scroll-up
// load-more paging, edited markers, failed-send retry, Shared files + Notes tabs,
// GIF picker + thread catch-up.
import SwiftUI

public struct ConversationView: View {
    @ObservedObject public var store: ConversationStore
    @ObservedObject private var presence: PresenceStore
    @ObservedObject public var call: CallStore
    @ObservedObject public var shared: SharedFilesStore
    @ObservedObject public var notes: NotesStore
    @ObservedObject public var catchUp: CatchUpStore
    /// False for 1:1 chats (header shows the chatmate dot).
    private let isGroup: Bool
    @State private var draft = ""
    @State private var lastSeenID: String?
    @State private var tab: Int
    @State private var showGIFs = false
    @AppStorage("tenorAPIKey") private var tenorAPIKey = ""
    @State private var showCatchUp: Bool
    @FocusState private var boxFocused: Bool

    /// - catchUpOpen: open the catch-up sheet at launch (the
    ///   --show-catchup shot hook only).
    public init(
        store: ConversationStore, presence: PresenceStore = PresenceStore(),
        call: CallStore = CallStore(), shared: SharedFilesStore = SharedFilesStore(),
        notes: NotesStore = NotesStore(), catchUp: CatchUpStore = CatchUpStore(),
        isGroup: Bool = true, initialTab: Int = 0, catchUpOpen: Bool = false
    ) {
        self.store = store
        self.presence = presence
        self.call = call
        self.shared = shared
        self.notes = notes
        self.catchUp = catchUp
        self.isGroup = isGroup
        _tab = State(initialValue: initialTab)
        _showCatchUp = State(initialValue: catchUpOpen)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("View", selection: $tab) {
                Text("Chat").tag(0)
                Text("Shared").tag(1)
                Text("Notes").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .onChange(of: tab) { syncShared() }
            Divider()
            if tab == 0 {
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
            } else if tab == 1 {
                SharedFilesView(store: shared)
                    .onAppear { syncShared() }
            } else {
                NotesView(store: notes)
            }
        }
        .frame(minWidth: 380, minHeight: 480)
        .onChange(of: store.chatID) { syncShared() }
        .sheet(isPresented: $showCatchUp) {
            CatchUpView(
                catchUp: catchUp, messages: store.messages,
                autoRun: CommandLine.arguments.contains("--show-catchup"))
        }
    }

    /// Lazily load the Shared tab when selected (no unsigned core calls
    /// from the Chat tab). Demo mode adopts canned files offline.
    private func syncShared() {
        guard tab == 1, let id = store.chatID else { return }
        guard shared.chatID != id else { return }
        if store.isDemo {
            shared.showDemo(chatID: id, files: DemoData.sharedFiles(for: id))
        } else {
            shared.open(chatID: id)
        }
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
                if let id = store.chatID {
                    Menu {
                        Button("Call (signaling only)") { call.place(threadID: id) }
                        Button("Call live (audio/video)") { call.placeLive(threadID: id) }
                    } label: {
                        Image(systemName: "phone")
                    }
                    .buttonStyle(.borderless)
                    .disabled(call.busy || (call.call?.isActive ?? false))
                    .help("Call this chat")
                }
                if CatchUp.shouldOffer(messageCount: store.messages.count) {
                    Button("Catch up", systemImage: "sparkles") {
                        catchUp.reset()
                        showCatchUp = true
                    }
                    .buttonStyle(.borderless)
                    .help("Summarize this thread: TL;DR, key points, action items")
                }
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
            Button {
                showGIFs = true
            } label: {
                Text("GIF")
                    .font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Insert a GIF (Tenor)")
            .popover(isPresented: $showGIFs, arrowEdge: .top) {
                TenorPickerView(apiKey: tenorAPIKey) { url in
                    insertGIF(url)
                    showGIFs = false
                }
            }
            TextField("Message", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($boxFocused)
                .onSubmit { submit() }
            Button("Send") { submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .onAppear {
            boxFocused = true
            // Shot hook: --show-gif opens the picker at launch.
            if CommandLine.arguments.contains("--show-gif") { showGIFs = true }
        }
    }

    private func submit() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        store.send(text: body)
    }

    /// Append a picked GIF URL to the draft (space-separated); the user
    /// still hits Send. Pure join so tests can pin the format.
    private func insertGIF(_ url: String) {
        draft = Self.appendGIF(url, to: draft)
        boxFocused = true
    }

    static func appendGIF(_ url: String, to draft: String) -> String {
        draft.isEmpty ? url : "\(draft) \(url)"
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
                let rendered = MessageRender.renderText(for: message)
                let images = MessageRender.images(fromRaw: message.raw)
                if !rendered.isEmpty {
                    Text(MessageRender.attributedBody(for: message))
                        .font(.body)
                        .tint(message.isOwn ? .white : .accentColor)
                        .textSelection(.enabled)
                }
                let emoticons = images.filter(\.isEmoticon)
                let photos = images.filter { !$0.isEmoticon }
                if !emoticons.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(emoticons.enumerated()), id: \.offset) { _, img in
                            RemoteEmoticon(url: img.url, messageID: message.id, alt: img.alt)
                        }
                    }
                }
                ForEach(Array(photos.enumerated()), id: \.offset) { _, img in
                    RemoteImage(url: img.url, messageID: message.id, alt: img.alt)
                }
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
