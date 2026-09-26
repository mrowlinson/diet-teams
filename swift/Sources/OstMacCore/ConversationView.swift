// ConversationView.swift — om-conv/om-convrich/om-shared/om-notes/om-cmdk/om-catchup/om-reactions/om-msgactions/om-replies/om-history/om-scroll/om-botposts/om-editdel/om-react-polish/om-catchup-sheet-dismiss/om-linkpreview: SwiftUI chat window.
// Rich bubbles (mentions, code spans, links), day separators, scroll-up
// load-more paging, edited markers, failed-send retry, Shared files + Notes tabs,
// GIF picker + thread catch-up + reaction picker/counts + copy/forward/save bubble menu,
// quote replies (bubble quote + compose chip), bot-post rows + placeholder,
// own-message edit/delete (top-level context menu).
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
    /// Pinned channel tabs (om-h4-tabs): row above the timeline for
    /// channel ids only; taps deep-link into Chat/Shared/Notes/browser.
    @ObservedObject public var tabs: ChannelTabsStore
    @ObservedObject public var catchUp: CatchUpStore
    /// On-device action-items extraction (f1-actions): same popover
    /// path as Catch-up, adjacent header entry.
    @ObservedObject public var actionItems: ActionItemsStore
    /// Live typing indicators (om-typing): passed to the timeline tail.
    @ObservedObject public var typing: TypingStore
    @ObservedObject public var receipts: ReceiptStore
    @ObservedObject public var attachments: ComposeAttachmentsStore
    /// Pinned messages per thread (om-pinmessages): passed to the timeline.
    @ObservedObject public var pins: PinnedMessageStore
    /// Cross-chat saved collection (e2-saved): passed to the timeline.
    @ObservedObject public var saved: SavedMessageStore
    /// Scheduled-send queue (d2-send): the clock button enqueues, the
    /// strip + sheet list this chat's pending items.
    @ObservedObject public var scheduled: ScheduledSendStore
    /// Canned-response templates (e2-canned): the templates button
    /// picks one into the draft.
    @ObservedObject public var canned: CannedResponsesStore
    /// False for 1:1 chats (header shows the chatmate dot).
    private let isGroup: Bool
    @State private var draft = ""
    @State private var tab: Int
    @State private var showGIFs = false
    @State private var showMentions = false
    @State private var showTemplates = false
    /// KLIPY key (Settings → GIFs), read from the keychain on appear
    /// and each time the picker opens (Settings may have changed it).
    @State private var gifAPIKey = ""
    @State private var showCatchUp: Bool
    @State private var showActionItems: Bool
    @FocusState private var boxFocused: Bool
    // (om-chat-convert): tool buttons are native .borderless (hover +
    // focus ring from AppKit) — no hand-rolled hover states.
    /// Schedule popover + pending sheet (d2-send). Shot hooks
    /// (--show-schedule / --show-scheduled) open them at launch.
    @State private var showSchedule: Bool
    @State private var showScheduledList: Bool
    /// Custom fire time (schedule popover) + inline error.
    @State private var customFireDate = Date().addingTimeInterval(3600)
    @State private var scheduleError: String?
    /// File-drop hover (om-iu-dropquick): accent outline on sendBox.
    @State private var dropTargeted = false
    /// Forward tap (om-msgactions): the host opens its jump-palette sheet
    /// (OstMac target owns JumpPaletteView; this module cannot import it).
    private let onForward: (ChatMessage) -> Void
    /// Channel context for saves (e2-saved): the team/channel ids behind
    /// one chat id (nil for plain chats). The host walks its teams model.
    private let savedContext: (String) -> (teamID: String?, channelID: String?)
    /// Edit sheet target + draft (om-editdel).
    @State private var editingMessage: ChatMessage?
    @State private var editDraft = ""
    /// Delete confirm target (om-editdel).
    @State private var deletingMessage: ChatMessage?
    @State private var showDeleteConfirm = false
    @State private var shotSeeded = false
    private let editOpen: Bool
    private let deleteOpen: Bool
    /// Preview-row tap (om-linkpreview passthrough to the timeline).
    private let onOpenLink: (URL) -> Void
    /// Draft tap (e1-popout): fired on every composer change so the host
    /// caches per-chat drafts (pop-out close loses nothing). Nil = unwired.
    private let onDraftChange: ((String) -> Void)?

    /// - catchUpOpen: open the catch-up sheet at launch (the
    ///   --show-catchup shot hook only).
    /// - onForward: bubble Forward tap → host sheets the jump palette.
    /// - editOpen/deleteOpen: open the edit sheet / delete confirm for the
    ///   first own bubble at launch (--show-edit / --show-delete shot hooks).
    /// - scheduleOpen/scheduledListOpen: open the schedule popover /
    ///   pending sheet at launch (--show-schedule / --show-scheduled
    ///   shot hooks).
    public init(
        store: ConversationStore, presence: PresenceStore = PresenceStore(),
        call: CallStore = CallStore(), shared: SharedFilesStore = SharedFilesStore(),
        notes: NotesStore = NotesStore(), tabs: ChannelTabsStore = ChannelTabsStore(),
        catchUp: CatchUpStore = CatchUpStore(),
        actionItems: ActionItemsStore = ActionItemsStore(),
        typing: TypingStore = TypingStore(),
        receipts: ReceiptStore = ReceiptStore(),
        attachments: ComposeAttachmentsStore = ComposeAttachmentsStore(),
        pins: PinnedMessageStore = PinnedMessageStore(),
        saved: SavedMessageStore = SavedMessageStore(),
        scheduled: ScheduledSendStore = ScheduledSendStore(),
        canned: CannedResponsesStore = CannedResponsesStore(),
        isGroup: Bool = true, initialTab: Int = 0, catchUpOpen: Bool = false,
        onForward: @escaping (ChatMessage) -> Void = { _ in },
        editOpen: Bool = false, deleteOpen: Bool = false,
        scheduleOpen: Bool = false, scheduledListOpen: Bool = false,
        onOpenLink: @escaping (URL) -> Void = { LinkPreviewOpen.default($0) },
        initialDraft: String = "",
        onDraftChange: ((String) -> Void)? = nil,
        savedContext: @escaping (String) -> (teamID: String?, channelID: String?) = { _ in (nil, nil) }
    ) {
        self.store = store
        self.presence = presence
        self.call = call
        self.shared = shared
        self.notes = notes
        self.tabs = tabs
        self.catchUp = catchUp
        self.actionItems = actionItems
        self.typing = typing
        self.receipts = receipts
        self.attachments = attachments
        self.pins = pins
        self.saved = saved
        self.savedContext = savedContext
        self.scheduled = scheduled
        self.canned = canned
        self.isGroup = isGroup
        self.onForward = onForward
        _tab = State(initialValue: initialTab)
        _showCatchUp = State(initialValue: catchUpOpen)
        _showActionItems = State(initialValue: false)
        self.editOpen = editOpen
        self.deleteOpen = deleteOpen
        _showSchedule = State(initialValue: scheduleOpen)
        _showScheduledList = State(initialValue: scheduledListOpen)
        // Shot hook: --show-schedule seeds a draft so the popover shows
        // its enabled presets (real launches start blank).
        if scheduleOpen {
            _draft = State(initialValue: "Standup moved to 10 — heads-up for the team.")
        } else if !initialDraft.isEmpty {
            _draft = State(initialValue: initialDraft)
        }
        self.onOpenLink = onOpenLink
        self.onDraftChange = onDraftChange
    }

    public var body: some View {
        VStack(spacing: 0) {
            DietHeaderBar {
                headerContent
            }
            // The empty-state already carries the error on the Chat tab
            // (with retry), so the banner stands down there — everywhere
            // else it surfaces the failure without blanking the view.
            if let err = store.error, tab != 0 || !store.messages.isEmpty || store.loading {
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
            // Channel tabs row (om-h4-tabs): channels only; taps
            // deep-link into this picker's tabs (or the browser).
            if ChannelTabsStore.isChannelID(store.chatID ?? "") {
                TeamsTabsView(store: tabs, selected: tabTarget) { selectTabTarget($0) }
            }
            DietSeamH()
            if tab == 0 {
                // Per-chat identity: fresh scroll model/sentinel/settle per
                // chat (see ChatTimelineView).
                ChatTimelineView(
                    store: store, typing: typing, onForward: onForward,
                    onEdit: beginEdit, onDelete: beginDelete,
                    sharedFiles: shared.chatID == store.chatID ? shared.files : [],
                    onOpenDoc: { _ = shared.open($0.file) },
                    receipts: receipts,
                    pins: pins,
                    saved: saved,
                    savedContext: savedContext,
                    onOpenLink: onOpenLink)
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
        .onChange(of: store.chatID) { syncShared(); syncTabs() }
        .onChange(of: store.messages.count) { syncShared() }
        .onAppear { syncTabs() }
        // om-catchup-sheet-dismiss: popover, not a window-modal sheet —
        // only a popover dismisses on click-outside. Done → dismissViaDone,
        // Esc → dismissViaEscape (explicit, works from any focus), and the
        // onChange net → dismissViaClickOutside for click-outside + any
        // other system dismiss. Every path closes AND resets the summary.
        .popover(isPresented: $showCatchUp, arrowEdge: .top) {
            CatchUpView(
                catchUp: catchUp, messages: store.messages,
                autoRun: CommandLine.arguments.contains("--show-catchup"),
                onDone: { CatchUpSheet.dismissViaDone(presented: $showCatchUp, store: catchUp) })
                .onExitCommand { CatchUpSheet.dismissViaEscape(presented: $showCatchUp, store: catchUp) }
        }
        .onChange(of: showCatchUp) { _, isOpen in
            // System dismiss (click-outside, Esc): the binding is already
            // false; the router call resets the summary state. Setting
            // false → false never retriggers this handler.
            if !isOpen { CatchUpSheet.dismissViaClickOutside(presented: $showCatchUp, store: catchUp) }
        }
        // f1-actions: same popover path as Catch-up (Done + Esc +
        // click-outside; every close resets the extraction state).
        .popover(isPresented: $showActionItems, arrowEdge: .top) {
            ActionItemsView(
                actions: actionItems, messages: store.messages,
                chatID: store.chatID,
                autoRun: CommandLine.arguments.contains("--show-action-items"),
                onDone: { ActionItemsSheet.dismissViaDone(presented: $showActionItems, store: actionItems) })
                .onExitCommand { ActionItemsSheet.dismissViaEscape(presented: $showActionItems, store: actionItems) }
        }
        .onChange(of: showActionItems) { _, isOpen in
            if !isOpen { ActionItemsSheet.dismissViaClickOutside(presented: $showActionItems, store: actionItems) }
        }
        .task {
            // --show-action-items: open after the thread settles (an
            // at-appear flip races view recreation and orphans a blank
            // popover window; real taps always come from the header
            // button).
            if CommandLine.arguments.contains("--show-action-items") {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !showActionItems, !store.messages.isEmpty {
                    ActionItemsSheet.open(presented: $showActionItems, store: actionItems)
                }
            }
        }
        .sheet(item: $editingMessage) { msg in
            editSheet(for: msg)
        }
        .alert(
            "Delete this message?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                if let target = deletingMessage {
                    store.deleteMessage(id: target.id)
                }
                deletingMessage = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { deletingMessage = nil }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear { seedEditDeleteShot() }
        .onChange(of: store.messages.count) { seedEditDeleteShot() }
    }

    /// Open the edit sheet for one bubble (draft preseeded from content).
    private func beginEdit(_ msg: ChatMessage) {
        editDraft = msg.content
        editingMessage = msg
    }

    /// Open the delete confirm for one bubble.
    private func beginDelete(_ msg: ChatMessage) {
        deletingMessage = msg
        showDeleteConfirm = true
    }

    /// Shot hooks: --show-edit / --show-delete open the sheet/confirm for
    /// the first own bubble once messages land (demo offline).
    private func seedEditDeleteShot() {
        guard !shotSeeded else { return }
        guard editOpen || deleteOpen else { return }
        guard let own = store.messages.first(where: \.isOwn) else { return }
        shotSeeded = true
        if editOpen {
            beginEdit(own)
        } else {
            beginDelete(own)
        }
    }

    private func editSheet(for msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            Text("Edit message")
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
            TextField("Message", text: $editDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .plainPasteFallback(into: $editDraft)
                .font(DietType.body)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editingMessage = nil }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.edit(messageID: msg.id, text: editDraft)
                    editingMessage = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || editDraft.trimmingCharacters(in: .whitespacesAndNewlines) == msg.content)
            }
        }
        .padding(DietSpace.md)
        .frame(minWidth: 320, idealWidth: 400)
    }

    /// Prefetch gate (om-fix-tabs): Shared loads on every chat change,
    /// whatever tab is showing — by the time the user taps Shared the
    /// rows are cached and the switch is instant (native, no wait, no
    /// custom transition). Pure, testable.
    public nonisolated static func shouldPrefetchShared(sharedChatID: String?, chatID: String?) -> Bool {
        guard let chatID else { return false }
        return sharedChatID != chatID
    }

    /// Prefetch the Shared list on conversation open (metadata only,
    /// never bytes). Demo mode adopts canned files offline. Inline doc
    /// rows resolve against the prefetched list in memory.
    private func syncShared() {
        guard let id = store.chatID else { return }
        guard Self.shouldPrefetchShared(sharedChatID: shared.chatID, chatID: id) else { return }
        loadShared(id: id)
    }

    private func loadShared(id: String) {
        if store.isDemo {
            shared.showDemo(chatID: id, files: DemoData.sharedFiles(for: id))
        } else {
            shared.open(chatID: id)
        }
    }

    /// Channel tabs follow the open conversation (om-h4-tabs). Channels
    /// fetch once per id; plain chats reset the row to idle (no fetch).
    private func syncTabs() {
        guard let id = store.chatID else { return }
        if ChannelTabsStore.isChannelID(id) {
            guard tabs.channelID != id else { return }
            tabs.open(channelID: id)
        } else if tabs.channelID != nil || !tabs.tabs.isEmpty {
            tabs.open(channelID: id) // non-channel: reset, no network
        }
    }

    /// Picker tab as a tab target (highlights the matching chip).
    private var tabTarget: ChannelTabTarget {
        switch tab {
        case 1: .shared
        case 2: .notes
        default: .chat
        }
    }

    /// Chip tap: well-known tabs switch this picker's tab instantly
    /// (Shared/Notes are prefetched on open, never on tap); website tabs
    /// open in the browser.
    private func selectTabTarget(_ target: ChannelTabTarget) {
        switch target {
        case .chat: tab = 0
        case .shared: tab = 1
        case .notes: tab = 2
        case let .web(url): onOpenLink(url)
        case .none: break
        }
    }

    private var headerContent: some View {
        HStack(spacing: DietSpace.sm) {
            if !isGroup, let id = store.chatID,
               let dot = DietPresence(teamsAvailability: presence.availabilityForChat(id))
            {
                DietPresenceDot(dot)
            }
            Text(store.headerTitle)
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
                .accessibilityLabel("Call options")
                .help("Call this chat")
            }
            if CatchUp.shouldOffer(messageCount: store.messages.count) {
                Button("Catch up", systemImage: "sparkles") {
                    CatchUpSheet.open(presented: $showCatchUp, store: catchUp)
                }
                .buttonStyle(.bordered)
                .help("Summarize this thread: TL;DR, key points, action items")
                Button("Action items", systemImage: "checklist") {
                    ActionItemsSheet.open(presented: $showActionItems, store: actionItems)
                }
                .buttonStyle(.bordered)
                .help("Extract action items on this Mac (Apple Intelligence)")
            }
            if store.loading { ProgressView().controlSize(.small) }
            Text("\(store.messages.count)")
                .font(DietType.captionMono)
                .foregroundStyle(DietColor.textSecondaryColor)
                .help("\(store.messages.count) messages loaded")
                .accessibilityLabel("\(store.messages.count) messages")
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
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancel reply")
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
            attachmentStrip
            scheduledStrip
            // (composer-rearrange): 5 controls lead in a 3-over-2 stack,
            // 2-line input center, Send trailing right. Stack height (two
            // rows + xs gap) matches the 48pt field. All 5 tool buttons
            // share the ComposerMetrics cell.
            HStack(alignment: .center, spacing: DietSpace.sm) {
                VStack(spacing: DietSpace.xs) {
                    HStack(spacing: DietSpace.sm) {
                        Button {
                            pickAttachments()
                        } label: {
                            Image(systemName: "paperclip")
                                .font(.system(size: DietSize.iconMD))
                                .frame(
                                    minWidth: ComposerMetrics.toolButtonWidth,
                                    minHeight: ComposerMetrics.toolButtonHeight)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Attach a file")
                        .help("Attach a file (<4 MB)")
                        .disabled(attachments.uploading)
                        Button {
                            showMentions = true
                        } label: {
                            Image(systemName: "at")
                                .font(.system(size: DietSize.iconMD))
                                .frame(
                                    minWidth: ComposerMetrics.toolButtonWidth,
                                    minHeight: ComposerMetrics.toolButtonHeight)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Mention someone")
                        .help("Mention someone (@)")
                        .popover(isPresented: $showMentions, arrowEdge: .top) {
                            MentionPickerView(
                                roster: MentionCompose.roster(
                                    from: store.messages, excluding: store.ownDisplayName)
                            ) { name in
                                insertMention(name)
                                showMentions = false
                            }
                        }
                        Button {
                            refreshGIFKey()
                            showGIFs = true
                        } label: {
                            Text("GIF")
                                .font(DietType.caption1).bold()
                                .frame(
                                    minWidth: ComposerMetrics.toolButtonWidth,
                                    minHeight: ComposerMetrics.toolButtonHeight)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Insert a GIF")
                        .help("Insert a GIF (KLIPY)")
                        .popover(isPresented: $showGIFs, arrowEdge: .top) {
                            KlipyPickerView(apiKey: gifAPIKey) { url in
                                insertGIF(url)
                                showGIFs = false
                            }
                        }
                    }
                    HStack(spacing: DietSpace.sm) {
                        // Schedule-send clock (d2-send, additive): opens the preset +
                        // custom-time popover. Queued sends fire while the app runs.
                        Button {
                            customFireDate = Date().addingTimeInterval(3600)
                            scheduleError = nil
                            showSchedule = true
                        } label: {
                            Image(systemName: "clock")
                                .font(.system(size: DietSize.iconMD))
                                .frame(
                                    minWidth: ComposerMetrics.toolButtonWidth,
                                    minHeight: ComposerMetrics.toolButtonHeight)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Schedule send")
                        .help("Schedule send (sends while the app is running)")
                        .popover(isPresented: $showSchedule, arrowEdge: .top) {
                            schedulePopover
                        }
                        // Templates button (e2-canned): same borderless-icon recipe
                        // as the tool stack; picking appends to the draft, never sends.
                        Button {
                            showTemplates = true
                        } label: {
                            Image(systemName: "doc.text")
                                .font(.system(size: DietSize.iconMD))
                                .frame(
                                    minWidth: ComposerMetrics.toolButtonWidth,
                                    minHeight: ComposerMetrics.toolButtonHeight)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Insert a template")
                        .help("Insert a template (Settings → Templates)")
                        .popover(isPresented: $showTemplates, arrowEdge: .top) {
                            CannedResponsesPickerView(templates: canned.templates) { template in
                                insertTemplate(template)
                                showTemplates = false
                            }
                        }
                    }
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .plainPasteFallback(into: $draft)
                    .font(DietType.body)
                    .lineLimit(ComposerMetrics.inputMinLines...)
                    .padding(DietSpace.sm)
                    .frame(minHeight: ComposerMetrics.inputMinHeight)
                    .background(
                        DietColor.wellColor,
                        in: RoundedRectangle(cornerRadius: DietRadius.control)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DietRadius.control)
                            .stroke(DietColor.dividerColor, lineWidth: 1)
                    )
                    .plainFocusRing()
                    .focused($boxFocused)
                    .onSubmit { submit() }
                    .onChange(of: draft) { onDraftChange?(draft) }
                Button("Send", systemImage: "paperplane.fill") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        attachments.uploading
                            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && !attachments.hasStaged))
            }
            .padding(DietSpace.md)
        }
        .onAppear {
            boxFocused = true
            // Shot hook: --shot-no-klipy skips the keychain read (a
            // prompting klipy item parks the main thread on
            // SecurityAgent mid-render and freezes shot automation).
            if CommandLine.arguments.contains("--shot-no-klipy") {
                gifAPIKey = ""
            } else {
                refreshGIFKey()
            }
            // Shot hook: --show-gif opens the picker at launch.
            if CommandLine.arguments.contains("--show-gif") { showGIFs = true }
            // Shot hook (om-a3-keyboard): --show-mention opens the @
            // picker at launch (before/after proof for keyboard nav).
            if CommandLine.arguments.contains("--show-mention") { showMentions = true }
            // Shot hook (e2-canned): --show-templates opens the
            // template picker at launch.
            if CommandLine.arguments.contains("--show-templates") { showTemplates = true }
        }
        // File drops stage like picker output (same cap gate); the
        // attachment strip above shows the staged rows.
        .onDrop(of: FileDrop.dropTypes, isTargeted: $dropTargeted) { providers in
            FileDrop.resolve(providers: providers) { attachments.stage(paths: $0) }
            return true
        }
        .dropHighlight(active: dropTargeted)
        // Pending queue sheet (d2-send): this chat's queued sends with
        // Cancel + Edit (edit returns the text to the draft).
        .sheet(isPresented: $showScheduledList) {
            ScheduledPendingSheet(
                scheduled: scheduled,
                chatID: store.chatID ?? "",
                chatName: store.headerTitle
            ) { text in
                draft = text
                boxFocused = true
            }
        }
    }

    private func submit() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFiles = attachments.hasStaged
        guard !body.isEmpty || hasFiles else { return }
        guard !attachments.uploading else { return }
        draft = ""
        // Files upload first (existing files-upload path), then the text
        // posts; failures stay in the composer for retry/remove while the
        // text still sends. Demo mode fabricates the upload offline.
        if hasFiles, let id = store.chatID {
            let demo = store.isDemo
            Task {
                await attachments.uploadPending(chatID: id, isDemo: demo)
                attachments.clearFinished()
                if !body.isEmpty { store.send(text: body) }
            }
        } else if !body.isEmpty {
            store.send(text: body)
        }
    }

    /// This chat's pending queue (d2-send), oldest first. Empty when no
    /// chat is open.
    private var pendingScheduled: [ScheduledItem] {
        guard let id = store.chatID else { return [] }
        return scheduled.pending(for: id)
    }

    /// Enqueue the draft for `fireAt`: clears the draft + closes the
    /// popover on success, else shows the inline error (blank draft,
    /// staged attachments — text-only v1 — or a past custom time).
    private func scheduleDraft(fireAt: Date) {
        guard let id = store.chatID else {
            scheduleError = "Open a chat first."
            return
        }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            scheduleError = "Write a message first."
            return
        }
        guard !attachments.hasStaged else {
            scheduleError = "Scheduled sends are text-only — remove attachments first."
            return
        }
        guard scheduled.enqueue(
            chatID: id, chatName: store.chatName ?? "",
            text: body, fireAt: fireAt) != nil
        else {
            scheduleError = "Pick a future time."
            return
        }
        draft = ""
        scheduleError = nil
        showSchedule = false
    }

    /// Schedule popover: presets + custom date/time, native controls.
    /// Honest copy (client-side only: the app must be running).
    private var schedulePopover: some View {
        let draftBlank = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: DietSpace.sm) {
            Text("Send later")
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
            Button("In 1 hour") {
                scheduleDraft(fireAt: ScheduledPresets.inOneHour())
            }
            .disabled(draftBlank)
            Button("Tonight 8 PM") {
                scheduleDraft(fireAt: ScheduledPresets.tonight8PM())
            }
            .disabled(draftBlank)
            Button("Tomorrow 9 AM") {
                scheduleDraft(fireAt: ScheduledPresets.tomorrow9AM())
            }
            .disabled(draftBlank)
            Divider()
            DatePicker(
                "Custom time", selection: $customFireDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute])
            .disabled(draftBlank)
            Button("Schedule for \(ScheduledPresets.fireLabel(for: customFireDate))") {
                scheduleDraft(fireAt: customFireDate)
            }
            .disabled(draftBlank)
            .buttonStyle(.borderedProminent)
            if draftBlank {
                Text("Write a message to schedule it.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            if let scheduleError {
                Text(scheduleError)
                    .font(DietType.caption1)
                    .foregroundStyle(.red)
            }
            Text("Sends while the app is running.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        .padding(DietSpace.md)
        .frame(minWidth: 280)
    }

    /// Pending strip (d2-send): one slim row above the send row while
    /// this chat has queued sends; opens the pending sheet. Hidden at
    /// zero (no layout shift otherwise).
    private var scheduledStrip: some View {
        Group {
            let pending = pendingScheduled
            if !pending.isEmpty {
                HStack(spacing: DietSpace.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: DietSize.iconSM))
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Button("\(pending.count) scheduled") {
                        showScheduledList = true
                    }
                    .buttonStyle(.link)
                    .font(DietType.caption1)
                    .accessibilityLabel("\(pending.count) scheduled sends")
                    .plainFocusRing()
                    Spacer(minLength: DietSpace.sm)
                    Text(ScheduledPresets.fireLabel(for: pending[0].fireAt))
                        .font(DietType.captionMono)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .padding(.horizontal, DietSpace.md)
                .padding(.top, DietSpace.sm)
            }
        }
    }

    /// Staged-file rows above the send row: name, size, per-file state
    /// (size flag / progress / sent / failed+retry), remove, and the upload
    /// error banner. No counts (Diagnostics only) — just the rows.
    private var attachmentStrip: some View {
        Group {
            if !attachments.attachments.isEmpty || attachments.error != nil {
                VStack(alignment: .leading, spacing: DietSpace.xs) {
                    ForEach(attachments.attachments) { file in
                        attachmentRow(for: file)
                    }
                    if let err = attachments.error {
                        DietBanner(.error, message: err) {
                            attachments.clearError()
                        }
                    }
                }
                .padding(.horizontal, DietSpace.md)
                .padding(.top, DietSpace.sm)
            }
        }
    }

    private func attachmentRow(for file: ComposeAttachment) -> some View {
        HStack(spacing: DietSpace.xs) {
            Image(systemName: SharedFile.iconName(mime: nil, filename: file.name))
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(DietColor.textSecondaryColor)
            Text(file.name)
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textPrimaryColor)
                .lineLimit(1)
            Text(SharedFile.sizeLabel(file.size))
                .font(DietType.captionMono)
                .foregroundStyle(DietColor.textSecondaryColor)
            Spacer(minLength: DietSpace.sm)
            switch file.state {
            case .staged:
                Text("Ready")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            case let .tooLarge(actual):
                Text(ComposeAttachments.capMessage(actual: actual))
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
            case .uploading:
                if let frac = attachments.uploadProgress[file.id] {
                    Text("\(Int((frac * 100).rounded()))%")
                        .font(DietType.captionMono)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                ProgressView().controlSize(.small)
            case .uploaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Text(message)
                    .font(DietType.caption1)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button("Retry") { attachments.retry(id: file.id) }
                    .buttonStyle(.link)
                    .font(DietType.caption1)
            }
            if file.state != .uploading {
                Button {
                    attachments.remove(id: file.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DietSize.iconMD))
                        .foregroundStyle(DietColor.textTertiaryColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove attachment")
                .help("Remove attachment")
            }
        }
    }

    /// Native file picker (multi-select); the store probes sizes and gates
    /// the 4 MB cap at stage time, before any upload.
    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            attachments.stage(urls: panel.urls)
        }
    }

    /// Re-read the KLIPY key (d2-send: off the main thread — a
    /// synchronous keychain read here wedged first render behind an
    /// unanswerable securityd round-trip; the picker lands a frame
    /// later when the read is slow).
    private func refreshGIFKey() {
        Task {
            let key = await Task.detached { KlipyClient.storedKey() }.value
            gifAPIKey = key
        }
    }

    /// Append a picked GIF URL to the draft (space-separated); the user
    /// still hits Send. Pure join so tests can pin the format.
    private func insertGIF(_ url: String) {
        draft = Self.appendGIF(url, to: draft)
        boxFocused = true
    }

    /// Append a picked @-mention to the draft (`@Name `, MentionCompose
    /// spacing); the user still hits Send. Plain text — the send path
    /// is untouched.
    private func insertMention(_ name: String) {
        draft = MentionCompose.insert(name, into: draft)
        boxFocused = true
    }

    /// Append a picked template body to the draft (e2-canned APPEND
    /// decision: never clobbers user text); the user still hits Send.
    /// Draft-local — the timeline never touches this path (zero-refresh).
    private func insertTemplate(_ template: CannedTemplate) {
        draft = CannedResponses.insert(template.body, into: draft)
        boxFocused = true
    }

    static func appendGIF(_ url: String, to draft: String) -> String {
        draft.isEmpty ? url : "\(draft) \(url)"
    }

    /// Shot-hook parse (om-history): `--scroll-to <message-id>` lands the
    /// initial scroll on that bubble. The canonical implementation lives
    /// on ChatTimelineView (the list owner); this shim keeps existing
    /// callers and HistoryTests compiling.
    static func scrollTarget(args: [String]) -> String? {
        ChatTimelineView.scrollTarget(args: args)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var failed: Bool = false
    /// Own display name for the mine wash (om-mentions): mention spans
    /// matching it get the accent highlight. Nil disables the wash.
    var highlightName: String? = nil
    /// Resolved quote parent (om-replies); nil for plain bubbles and
    /// evicted parents (the fallback line covers the latter).
    var quoted: ChatMessage?
    var onRetry: () -> Void = {}
    /// Picker tap (om-reactions): the host toggles this emoji on the bubble.
    var onReact: (String) -> Void = { _ in }
    /// Forward tap (om-msgactions): the host sheets the jump palette.
    var onForward: () -> Void = {}
    var onReply: () -> Void = {}
    /// Edit/delete (om-editdel): own bubbles only, top-level menu items.
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    /// Loaded Shared-tab files for this chat (om-inline-docs): doc refs
    /// resolve against them in memory (no fetch). Empty until the Shared
    /// tab (or ref preload) loads — unresolved refs keep old behavior.
    var sharedFiles: [SharedFile] = []
    /// Doc-row Open tap (om-inline-docs): the host previews the file
    /// (SharedFilesStore.open parity). Default opens the SharePoint page.
    var onOpenDoc: (InlineDoc) -> Void = { InlineDocs.open($0) }
    /// Own-message read state (om-receipts): some peer frontier sits at
    /// or past this bubble. Own bubbles only; others ignore it.
    var isRead: Bool = false
    /// Preview-row tap (om-linkpreview): opens the cleaned https URL.
    /// Injected so tests never touch the browser; default is guarded
    /// (https-only, NSWorkspace).
    var onOpenLink: (URL) -> Void = { LinkPreviewOpen.default($0) }
    /// Pinned state (om-pinmessages): drives the Pin/Unpin menu label.
    var isPinned: Bool = false
    var onTogglePin: () -> Void = {}
    /// Saved state (e2-saved): drives the Save/Unsave message menu label.
    var isSaved: Bool = false
    var onToggleSave: () -> Void = {}
    /// Open chat id (om-jd-cardactions): feeds the "Open in Teams"
    /// fallback link. Nil (previews, tests) falls back to Teams home.
    var chatID: String? = nil
    /// Quote-strip tap (om-lt2-quotelink): the host scrolls to this
    /// parent id. Default no-op (previews, tests). Evicted parents
    /// never call it (fallback line is not a button).
    var onQuoteJump: (String) -> Void = { _ in }
    /// Inline translation (e1-translation): this bubble's cached entry
    /// (nil = never translated). The host's TranslationStore owns it.
    var translation: TranslatedEntry? = nil
    /// Translate tap (e1-translation): the host toggles/translates.
    var onTranslate: () -> Void = {}
    /// Message density (f2-density): bubble inner padding. Plain
    /// environment value — no new init param, existing callers
    /// untouched.
    @Environment(\.messageDensity) private var density

    var body: some View {
        HStack(spacing: DietSpace.xs) {
            if message.isOwn { Spacer(minLength: DietSpace.xxl) }
            // Failed marker rides OUTSIDE the bubble (DietBubble parity;
            // retry lives in the right-click menu, same as DietBubble's
            // context menu) — never an in-bubble row.
            if failed { DietBubbleFailedIcon() }
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
                                .foregroundStyle(DietColor.textSecondaryColor)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    quoteBlock
                    let rendered = MessageRender.bubbleText(for: message)
                    let images = MessageRender.images(fromRaw: message.raw)
                    let posts = MessageRender.botPosts(fromRaw: message.raw ?? message.content)
                    let docs = InlineDocs.docs(for: message, files: sharedFiles)
                    if !rendered.isEmpty {
                        // Selectable AND custom-menu: the bridge's local
                        // monitor swallows bubble right-clicks (popping
                        // our menu), so selection never hides the picker;
                        // left-drag selects, right-click reacts, Cmd+C
                        // copies the selection, and the bubble menu's Copy
                        // still takes the full message.
                        Text(MessageRender.attributedBody(text: rendered, raw: message.raw, highlighting: highlightName))
                            .font(DietType.body)
                            .tint(.accentColor)
                            .textSelection(.enabled)
                    }
                    // Inline translation (e1-translation): the translated
                    // text under the original (original always stays).
                    // Bubble-local growth only — stable row identity, no
                    // timeline refresh, no spinner (quiet captions).
                    if let t = translation, t.isVisible {
                        translationBlock(t)
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
                    let cards = MessageBubbleState.cards(for: message)
                    if !cards.isEmpty {
                        ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                            AdaptiveCardView(
                                card: card, messageID: message.id,
                                chatID: chatID)
                        }
                    }
                    if !posts.isEmpty, MessageBubbleState.shouldShowFallbackRows(posts: posts, cards: cards) {
                        BotPostRows(posts: posts)
                    }
                    // Card actions (om-jd-cardactions): rendered cards own
                    // their rows inside AdaptiveCardView (OpenUrl links +
                    // "Open in Teams" fallback); this decoupled block stays
                    // for non-card payloads (O365 connector actions etc).
                    // No-op without card actions.
                    let cardActions = cards.isEmpty
                        ? CardActions.actions(fromRaw: message.raw ?? message.content)
                        : .empty
                    if !cardActions.isEmpty {
                        CardActionRows(
                            actions: cardActions, chatID: chatID,
                            messageID: message.id)
                    }
                    if !docs.isEmpty {
                        InlineDocRows(docs: docs, onOpen: onOpenDoc)
                    }
                    // First-URL unfurl (om-linkpreview): one title row under
                    // the text. Suppressed for bot-post bubbles (their rows
                    // already carry titles) and text-less bubbles (card JSON
                    // URLs are payload noise, never user links). Any fetch
                    // failure collapses to nothing — the inline link stays.
                    let linkCandidate = (posts.isEmpty && !rendered.isEmpty)
                        ? LinkPreviewParse.firstCandidate(content: rendered, raw: message.raw)
                        : nil
                    if let linkCandidate {
                        LinkPreviewSlot(urlString: linkCandidate, onOpen: onOpenLink)
                    }
                    if MessageRender.showsPlaceholder(for: message), docs.isEmpty {
                        Text("Bot post unavailable")
                            .font(DietType.caption1)
                            .italic()
                            .foregroundStyle(DietColor.textSecondaryColor)
                            .accessibilityLabel("Unsupported post format")
                    }
                    if message.isOwn, isRead, !failed {
                        HStack(spacing: DietSpace.xxs) {
                            Image(systemName: "checkmark")
                                .font(.system(size: DietSize.iconMD))
                            Text("Seen")
                                .font(DietType.caption2)
                        }
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Seen")
                    }
            }
            .padding(density.metrics.bubblePad)
            .background(
                message.isOwn ? DietColor.bubbleOutColor : DietColor.bubbleInColor,
                in: RoundedRectangle(cornerRadius: DietRadius.bubble))
            .overlay(
                failed ? RoundedRectangle(cornerRadius: DietRadius.bubble)
                    .stroke(Color(nsColor: DietColor.danger), lineWidth: 1) : nil)
            .foregroundStyle(DietColor.textPrimaryColor)
            .opacity(failed ? 0.85 : 1)
            // Right-click menu via AppKit bridge: ONE menu (inline emoji
            // row + Reply / Copy / Forward / Save / Pin-Unpin, all
            // top-level, no submenu — see ReactionMenuBridge). A covering
            // overlay is deliberately NOT used: the monitor approach leaves
            // links and badge taps untouched.
            .background(
                ReactionMenuBridge(
                    message: message, onReact: onReact, failed: failed,
                    onCopy: { copyBody() }, onForward: onForward,
                    onSave: { saveBody() }, onRetry: onRetry,
                    onReply: onReply, onEdit: onEdit, onDelete: onDelete,
                    isPinned: isPinned, onTogglePin: onTogglePin,
                    isSaved: isSaved, onToggleSave: onToggleSave,
                    canTranslate: MessageTranslation.isEligible(message),
                    onTranslate: onTranslate))
            // Keyboard/VO path (om-a3-keyboard): the bubble takes focus
            // and exposes the same actions as a native context menu.
            // Right-clicks still land on the AppKit menu (its monitor
            // swallows them first); this menu only surfaces through
            // keyboard / VoiceOver menu invocation on a focused bubble.
            .focusable()
            .contextMenu { keyboardMenu }
            if !message.reactions.isEmpty {
                ReactionTapbacks(reactions: message.reactions, onTap: onReact)
                    .offset(x: message.isOwn ? DietSpace.sm : -DietSpace.sm, y: -DietSpace.md)
            }
        }
        if !message.isOwn { Spacer(minLength: DietSpace.xxl) }
        }
        // Badge clearance: reacted bubbles reserve the badges' overhang
        // above (same constant the menu hit rect uses), so tapbacks never
        // collide with the message above.
        .padding(.top, message.reactions.isEmpty ? 0 : ReactionMenuAnchorView.badgeOverhang)
    }

    /// Native context menu for the keyboard/VO path (om-a3-keyboard):
    /// same actions, same titles as the AppKit right-click menu. React
    /// opens the more-picker through the bubble's anchor (keyboard use
    /// means frontmost, so no retry). Kept beside the bridge call so
    /// the two menus can't drift silently.
    @ViewBuilder
    private var keyboardMenu: some View {
        Button("React…") {
            NotificationCenter.default.post(
                name: ReactionMenuAnchorView.keyboardPickerNote,
                object: message.id)
        }
        Divider()
        Button("Reply", action: onReply)
        Button("Copy") { copyBody() }
        Button("Forward…", action: onForward)
        Button("Save…") { saveBody() }
        if MessageTranslation.isEligible(message) {
            Button(MessageTranslation.menuTitle, action: onTranslate)
        }
        Button(PinnedMessages.menuTitle(isPinned: isPinned), action: onTogglePin)
        Button(SavedMessages.menuTitle(isSaved: isSaved), action: onToggleSave)
        if message.isOwn {
            Button("Edit…", action: onEdit)
            Button("Delete…", action: onDelete)
        }
        if failed {
            Button("Retry send", action: onRetry)
        }
    }

    /// Keyboard-menu titles in order (leading React… covers the AppKit
    /// emoji row). Must match ReactionMenuAnchorView.actionItems after
    /// the React… head (parity pinned by MessageTranslationTests —
    /// update BOTH with keyboardMenu above).
    static func keyboardMenuTitles(
        for message: ChatMessage, failed: Bool, isPinned: Bool,
        isSaved: Bool = false, canTranslate: Bool
    ) -> [String] {
        var titles = ["React…", "Reply", "Copy", "Forward…", "Save…"]
        if canTranslate {
            titles.append(MessageTranslation.menuTitle)
        }
        titles.append(PinnedMessages.menuTitle(isPinned: isPinned))
        titles.append(SavedMessages.menuTitle(isSaved: isSaved))
        if message.isOwn {
            titles += ["Edit…", "Delete…"]
        }
        if failed {
            titles.append("Retry send")
        }
        return titles
    }

    /// Inline translated-text block (e1-translation): divider + language
    /// tag + translated text in a secondary treatment, original above
    /// untouched. Quiet captions for pending/no-op/failure (no spinner,
    /// no skeleton — zero-refresh rule).
    @ViewBuilder
    private func translationBlock(_ t: TranslatedEntry) -> some View {
        Divider()
        switch t.state {
        case .pending:
            Text("Translating…")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .accessibilityLabel("Translating message")
        case .translated:
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                HStack(spacing: DietSpace.xs) {
                    Text(Self.translationTag(for: t))
                        .font(DietType.caption2)
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Spacer(minLength: DietSpace.sm)
                    Button("Show original", action: onTranslate)
                        .buttonStyle(.link)
                        .font(DietType.caption1)
                        .plainFocusRing()
                }
                Text(t.text)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        case .sameLanguage:
            Text("Already in \(MessageTranslation.displayName(for: t.targetCode))")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        case .failed:
            HStack(spacing: DietSpace.xs) {
                Text("Translation unavailable")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                Button("Retry", action: onTranslate)
                    .buttonStyle(.link)
                    .font(DietType.caption1)
                    .plainFocusRing()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "Translated from Spanish" (source known) or "Translated" + target.
    static func translationTag(for t: TranslatedEntry) -> String {
        if let src = t.sourceCode, !src.isEmpty {
            return "Translated from \(MessageTranslation.displayName(for: src))"
        }
        return "Translated to \(MessageTranslation.displayName(for: t.targetCode))"
    }

    /// "Remove 👍" when the bubble already shows it, else "React 👍".
    static func reactHelp(emoji: String, on message: ChatMessage) -> String {
        message.reactions.contains(where: { $0.emoji == emoji })
            ? "Remove \(emoji)" : "React \(emoji)"
    }

    /// Copy the bubble (text + rich) through the injected live writer.
    private func copyBody() {
        MessageActions.copy(
            message, highlighting: highlightName,
            write: MessageActions.liveCopyWriter)
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
    /// + preview with an accent bar as a jump link to the parent bubble;
    /// an evicted parent shows a muted fallback so the reply link is
    /// never silently dropped.
    @ViewBuilder
    private var quoteBlock: some View {
        if let parent = quoted {
            Button { onQuoteJump(parent.id) } label: {
                HStack(spacing: DietSpace.xs) {
                    RoundedRectangle(cornerRadius: DietSpace.xxs)
                        .fill(Color.accentColor)
                        .frame(width: DietSpace.xs)
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
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .plainFocusRing()
            .help("Jump to quoted message")
            .padding(.vertical, DietSpace.xxs)
        } else if message.reply_to != nil {
            Text("↩ Original message not in history")
                .font(DietType.caption2)
                .italic()
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }
}

/// Bot-post rows (om-botposts): one native row per RSS/card item —
/// title as a Link when an http(s) URL parsed, plain title otherwise.
/// Links open in the default browser (Link's native behavior); only
/// http(s) schemes render as links.
struct BotPostRows: View {
    let posts: [MessageRender.BotPost]

    var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.xxs) {
            ForEach(Array(posts.enumerated()), id: \.offset) { _, post in
                if let target = Self.linkTarget(for: post) {
                    // Explicit accent + underline: the bubble's primary
                    // foregroundStyle would otherwise flatten links into
                    // plain text. Matches inline-link treatment.
                    Link(destination: target) {
                        Text(post.title).underline()
                    }
                    .font(DietType.body)
                    .foregroundStyle(Color.accentColor)
                } else {
                    Text(post.title)
                        .font(DietType.body)
                }
            }
        }
    }

    /// Parsed http(s) link target, or nil for title-only rows.
    static func linkTarget(for post: MessageRender.BotPost) -> URL? {
        guard let raw = post.url, let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
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
                .accessibilityElement(children: .combine)
                .plainFocusRing(radius: 12)
                .help(r.count > 1 ? "\(r.count) reactions" : "1 reaction")
            }
        }
    }
}

/// Pending scheduled-send sheet (d2-send): this chat's queued texts +
/// fire times, oldest first. Cancel drops without sending; Edit pulls
/// the text back into the composer draft. Native List in a Sheet.
struct ScheduledPendingSheet: View {
    @ObservedObject var scheduled: ScheduledSendStore
    let chatID: String
    let chatName: String
    /// Fires on Edit with the restored text (the host sets the draft).
    let onEdit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Scheduled for \(chatName)")
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
                .padding(.top, DietSpace.md)
            let pending = scheduled.pending(for: chatID)
            if pending.isEmpty {
                Text("Nothing scheduled in this chat.")
                    .font(DietType.callout)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .padding(DietSpace.lg)
            } else {
                List(pending) { item in
                    HStack(alignment: .firstTextBaseline, spacing: DietSpace.sm) {
                        VStack(alignment: .leading, spacing: DietSpace.xxs) {
                            Text(item.text)
                                .font(DietType.body)
                                .foregroundStyle(DietColor.textPrimaryColor)
                                .lineLimit(2)
                            Text(ScheduledPresets.fireLabel(for: item.fireAt))
                                .font(DietType.captionMono)
                                .foregroundStyle(DietColor.textSecondaryColor)
                        }
                        Spacer(minLength: DietSpace.sm)
                        Button("Edit") {
                            if let taken = scheduled.takeForEdit(id: item.id) {
                                onEdit(taken.text)
                            }
                            if scheduled.pending(for: chatID).isEmpty {
                                dismiss()
                            }
                        }
                        .buttonStyle(.link)
                        Button("Cancel", role: .destructive) {
                            scheduled.cancel(id: item.id)
                            if scheduled.pending(for: chatID).isEmpty {
                                dismiss()
                            }
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, DietSpace.xxs)
                }
                .listStyle(.plain)
            }
            Text("Queued sends fire while the app is running.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .padding(.bottom, DietSpace.md)
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}

