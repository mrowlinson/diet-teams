// ConversationView.swift — om-conv/om-convrich/om-shared/om-notes/om-cmdk/om-catchup/om-reactions/om-msgactions/om-replies/om-scroll: SwiftUI chat window.
// Rich bubbles (mentions, code spans, links), day separators, scroll-up
// load-more paging, edited markers, failed-send retry, Shared files + Notes tabs,
// GIF picker + thread catch-up + reaction picker/counts + copy/forward/save bubble menu,
// quote replies (bubble quote + compose chip).
import AppKit
import DietDesign
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var tab: Int
    @State private var showGIFs = false
    @AppStorage("tenorAPIKey") private var tenorAPIKey = ""
    @State private var showCatchUp: Bool
    @FocusState private var boxFocused: Bool
    @State private var gifHovering = false
    /// Forward tap (om-msgactions): the host opens its jump-palette sheet
    /// (OstMac target owns JumpPaletteView; this module cannot import it).
    private let onForward: (ChatMessage) -> Void

    /// - catchUpOpen: open the catch-up sheet at launch (the
    ///   --show-catchup shot hook only).
    /// - onForward: bubble Forward tap → host sheets the jump palette.
    public init(
        store: ConversationStore, presence: PresenceStore = PresenceStore(),
        call: CallStore = CallStore(), shared: SharedFilesStore = SharedFilesStore(),
        notes: NotesStore = NotesStore(), catchUp: CatchUpStore = CatchUpStore(),
        isGroup: Bool = true, initialTab: Int = 0, catchUpOpen: Bool = false,
        onForward: @escaping (ChatMessage) -> Void = { _ in }
    ) {
        self.store = store
        self.presence = presence
        self.call = call
        self.shared = shared
        self.notes = notes
        self.catchUp = catchUp
        self.isGroup = isGroup
        self.onForward = onForward
        _tab = State(initialValue: initialTab)
        _showCatchUp = State(initialValue: catchUpOpen)
    }

    public var body: some View {
        VStack(spacing: 0) {
            DietHeaderBar {
                headerContent
            }
            if let err = store.error {
                DietBanner(.error, message: err)
                    .padding(.horizontal, DietSpace.md)
                    .padding(.vertical, DietSpace.sm)
            }
            Picker("View", selection: $tab) {
                Text("Chat").tag(0)
                Text("Shared").tag(1)
                Text("Notes").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.sm)
            .onChange(of: tab) { syncShared() }
            DietSeamH()
            if tab == 0 {
                // Per-chat identity: fresh scroll model/sentinel/settle per
                // chat (see ChatTimelineView).
                ChatTimelineView(store: store, onForward: onForward)
                    .id("chat-\(store.chatID ?? "-")")
                DietSeamH()
                sendBox
            } else if tab == 1 {
                SharedFilesView(store: shared)
                    .onAppear { syncShared() }
            } else {
                NotesView(store: notes)
            }
        }
        .frame(minWidth: 380, minHeight: 480)
        .background(DietColor.windowColor)
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

    private var headerContent: some View {
        HStack(spacing: DietSpace.sm) {
            if !isGroup, let id = store.chatID,
               let dot = DietPresence(teamsAvailability: presence.availabilityForChat(id))
            {
                DietPresenceDot(dot)
            }
            Text(store.chatName ?? store.chatID ?? "Conversation")
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
                .lineLimit(1)
            if store.isDemo {
                Text("DEMO")
                    .font(DietType.caption2).bold()
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .padding(.horizontal, DietSpace.xs)
                    .padding(.vertical, DietSpace.xxs)
                    .background(
                        Color(nsColor: DietColor.warning).opacity(0.2),
                        in: Capsule())
            }
            Spacer(minLength: DietSpace.sm)
            if let id = store.chatID {
                Menu {
                    Button("Call (signaling only)") { call.place(threadID: id) }
                    Button("Call live (audio/video)") { call.placeLive(threadID: id) }
                } label: {
                    Image(systemName: "phone")
                        .font(.system(size: DietSize.iconMD))
                        .foregroundStyle(DietColor.textSecondaryColor)
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
                .buttonStyle(.dietSecondary)
                .help("Summarize this thread: TL;DR, key points, action items")
            }
            if store.loading { ProgressView().controlSize(.small) }
            Text("\(store.messages.count)")
                .font(DietType.captionMono)
                .foregroundStyle(DietColor.textTertiaryColor)
        }
    }

    /// Armed-reply chip: parent sender + preview with a ✕ disarm.
    private var replyChip: some View {
        Group {
            if let target = store.replyTarget {
                VStack(spacing: 0) {
                    HStack(spacing: DietSpace.xs) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: DietSize.iconMD))
                            .foregroundStyle(DietColor.textSecondaryColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Replying to \(target.sender)")
                                .font(DietType.caption1).bold()
                                .foregroundStyle(DietColor.textPrimaryColor)
                                .lineLimit(1)
                            Text(ConversationStore.quotePreview(target.content))
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                                .lineLimit(1)
                        }
                        Spacer(minLength: DietSpace.sm)
                        Button {
                            store.cancelReply()
                            boxFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: DietSize.iconMD))
                                .foregroundStyle(DietColor.textTertiaryColor)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel reply")
                    }
                    .padding(.horizontal, DietSpace.md)
                    .padding(.vertical, DietSpace.xs)
                    DietSeamH()
                }
            }
        }
    }

    private var sendBox: some View {
        VStack(spacing: 0) {
            replyChip
            HStack(spacing: DietSpace.sm) {
                Button {
                    showGIFs = true
                } label: {
                Text("GIF")
                    .font(DietType.caption1).bold()
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .padding(.horizontal, DietSpace.xs)
                    .padding(.vertical, DietSpace.xxs)
                    .background(
                        gifHovering ? DietColor.wellColor : .clear,
                        in: RoundedRectangle(cornerRadius: DietRadius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: DietRadius.control)
                            .stroke(DietColor.dividerColor, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { gifHovering = $0 }
            .help("Insert a GIF (Tenor)")
            .popover(isPresented: $showGIFs, arrowEdge: .top) {
                TenorPickerView(apiKey: tenorAPIKey) { url in
                    insertGIF(url)
                    showGIFs = false
                }
            }
            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .font(DietType.body)
                .foregroundStyle(DietColor.textPrimaryColor)
                .focused($boxFocused)
                .padding(.horizontal, DietSpace.sm)
                .frame(minHeight: DietSize.controlHeight)
                .background(DietColor.wellColor)
                .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: DietRadius.control)
                        .stroke(
                            boxFocused ? Color.accentColor : DietColor.dividerColor,
                            lineWidth: boxFocused ? 2 : 1)
                )
                .onSubmit { submit() }
                Button("Send", systemImage: "paperplane.fill") { submit() }
                    .buttonStyle(.dietPrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(DietSpace.md)
        }
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

}

struct MessageBubble: View {
    let message: ChatMessage
    var failed: Bool = false
    /// Resolved quote parent (om-replies); nil for plain bubbles and
    /// evicted parents (the fallback line covers the latter).
    var quoted: ChatMessage?
    var onRetry: () -> Void = {}
    /// Picker tap (om-reactions): the host toggles this emoji on the bubble.
    var onReact: (String) -> Void = { _ in }
    /// Forward tap (om-msgactions): the host sheets the jump palette.
    var onForward: () -> Void = {}
    var onReply: () -> Void = {}

    var body: some View {
        HStack(spacing: DietSpace.xs) {
            if message.isOwn { Spacer(minLength: DietSpace.xxl) }
            // Tapback badges overlap the bubble's top outer corner
            // (iMessage-style); later rows paint above, so the badge
            // straddling upward stays visible.
            ZStack(alignment: message.isOwn ? .topTrailing : .topLeading) {
                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                    HStack(spacing: DietSpace.xs) {
                        Text("\(message.sender) · \(message.displayTime)")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                        if message.edited {
                            Text("(edited)")
                                .font(DietType.caption2)
                                .italic()
                                .foregroundStyle(DietColor.textTertiaryColor)
                        }
                    }
                    quoteBlock
                    let rendered = MessageRender.renderText(for: message)
                    let images = MessageRender.images(fromRaw: message.raw)
                    if !rendered.isEmpty {
                        // No .textSelection: selectable Text owns the
                        // system menu and SwiftUI does not merge custom
                        // items into it, so selection would hide the
                        // picker on the words. Copy lives in the bubble
                        // menu instead (full message; partial selection
                        // awaits a TextKit-backed bubble).
                        Text(MessageRender.attributedBody(for: message))
                            .font(DietType.body)
                            .tint(.accentColor)
                    }
                    let emoticons = images.filter(\.isEmoticon)
                    let photos = images.filter { !$0.isEmoticon }
                    if !emoticons.isEmpty {
                        HStack(spacing: DietSpace.xs) {
                            ForEach(Array(emoticons.enumerated()), id: \.offset) { _, img in
                                RemoteEmoticon(url: img.url, messageID: message.id, alt: img.alt)
                            }
                        }
                    }
                    ForEach(Array(photos.enumerated()), id: \.offset) { _, img in
                        RemoteImage(url: img.url, messageID: message.id, alt: img.alt)
                    }
                    if failed {
                        HStack(spacing: DietSpace.xs) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: DietSize.iconMD))
                                .foregroundStyle(Color(nsColor: DietColor.danger))
                                .accessibilityLabel("Send failed")
                            Text("Not delivered")
                                .font(DietType.caption1)
                                .foregroundStyle(Color(nsColor: DietColor.danger))
                            Button("Retry", action: onRetry)
                                .font(DietType.caption1)
                                .buttonStyle(.link)
                                .tint(Color(nsColor: DietColor.danger))
                        }
                    }
            }
            .padding(DietSpace.sm + DietSpace.xs)
            .background(
                message.isOwn ? DietColor.bubbleOutColor : DietColor.bubbleInColor,
                in: RoundedRectangle(cornerRadius: DietRadius.bubble))
            .overlay(
                failed ? RoundedRectangle(cornerRadius: DietRadius.bubble)
                    .stroke(Color(nsColor: DietColor.danger), lineWidth: 1) : nil)
            .foregroundStyle(DietColor.textPrimaryColor)
            .opacity(failed ? 0.85 : 1)
            // Right-click menu via AppKit bridge: ONE menu (inline emoji
            // row + Reply / Copy / Forward / Save, all top-level, no
            // submenu — see ReactionMenuBridge). A covering overlay is
            // deliberately NOT used: the monitor approach leaves links
            // and badge taps untouched.
            .background(
                ReactionMenuBridge(
                    message: message, onReact: onReact, failed: failed,
                    onCopy: { copyBody() }, onForward: onForward,
                    onSave: { saveBody() }, onRetry: onRetry,
                    onReply: onReply))
            if !message.reactions.isEmpty {
                ReactionTapbacks(reactions: message.reactions, onTap: onReact)
                    .offset(x: message.isOwn ? DietSpace.sm : -DietSpace.sm, y: -DietSpace.md)
            }
        }
        if !message.isOwn { Spacer(minLength: DietSpace.xxl) }
        }
    }

    /// "Remove 👍" when the bubble already shows it, else "React 👍".
    static func reactHelp(emoji: String, on message: ChatMessage) -> String {
        message.reactions.contains(where: { $0.emoji == emoji })
            ? "Remove \(emoji)" : "React \(emoji)"
    }

    /// Full-message copy for the bubble menu (Auth.swift precedent).
    static func copyMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    /// Copy the bubble text (what the bubble shows) to the pasteboard.
    private func copyBody() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(MessageActions.copyText(for: message), forType: .string)
    }

    /// Save the bubble (sender + timestamp header + text) via a save panel.
    private func saveBody() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MessageActions.saveFilename(for: message)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? MessageActions.saveBody(for: message).write(
            to: url, atomically: true, encoding: .utf8)
    }

    /// Quoted parent strip above the body. Resolved parents show sender
    /// + preview with an accent bar; an evicted parent shows a muted
    /// fallback so the reply link is never silently dropped.
    @ViewBuilder
    private var quoteBlock: some View {
        if let parent = quoted {
            HStack(spacing: DietSpace.xs) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parent.sender)
                        .font(DietType.caption1).bold()
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(1)
                    Text(ConversationStore.quotePreview(parent.content))
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, DietSpace.xxs)
        } else if message.reply_to != nil {
            Text("↩ Original message not in history")
                .font(DietType.caption2)
                .italic()
                .foregroundStyle(DietColor.textTertiaryColor)
        }
    }
}

/// iMessage-style tapback badges (om-reactions): one capsule per emoji
/// with its count (count shown past 1), overlapping the bubble's top
/// corner via the caller's ZStack. Tapping a badge toggles that emoji,
/// same as the context-menu picker.
struct ReactionTapbacks: View {
    let reactions: [ReactionCount]
    var onTap: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: DietSpace.xxs) {
            ForEach(reactions, id: \.emoji) { r in
                Button { onTap(r.emoji) } label: {
                    HStack(spacing: DietSpace.xxs) {
                        Text(r.emoji)
                            .font(DietType.caption1)
                        if r.count > 1 {
                            Text("\(r.count)")
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                        }
                    }
                    .padding(.horizontal, DietSpace.xs)
                    .padding(.vertical, DietSpace.xxs)
                    .background(DietColor.cardColor, in: Capsule())
                    .overlay(
                        Capsule().stroke(DietColor.dividerColor, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .help(r.count > 1 ? "\(r.count) reactions" : "1 reaction")
            }
        }
    }
}

