// ChatTimelineView.swift — om-scroll/om-history/om-editdel/om-react-polish/om-scrollbottom/om-pinmessages:
// message timeline with follow/pill, prepend anchoring, armed+debounced
// paging, history loading/error states, edit/delete passthrough, the
// more-picker shot hook, settle re-asserts, a jump-to-latest while
// scrolled up with nothing new, and the pinned strip (tap jumps).
//
// Extracted from ConversationView so the scroll state (ChatScrollModel)
// is owned per chat: the parent `.id()`s this view by chatID, giving
// each chat a fresh model, sentinel, and settle generation.
import DietDesign
import SwiftUI

struct ChatTimelineView: View {
    @ObservedObject var store: ConversationStore
    /// Live typing indicators (om-typing): the tail row reads this.
    @ObservedObject var typing: TypingStore = TypingStore()
    var onForward: (ChatMessage) -> Void = { _ in }
    var onEdit: (ChatMessage) -> Void = { _ in }
    var onDelete: (ChatMessage) -> Void = { _ in }
    /// Loaded Shared-tab files for this chat (om-inline-docs passthrough).
    var sharedFiles: [SharedFile] = []
    /// Doc-row Open tap (om-inline-docs passthrough).
    var onOpenDoc: (InlineDoc) -> Void = { InlineDocs.open($0) }
    /// Read receipts (om-receipts): viewed-latest sends + own Seen state.
    @ObservedObject var receipts: ReceiptStore = ReceiptStore()
    /// Pinned messages (om-pinmessages): the strip + bubble menu state.
    @ObservedObject var pins: PinnedMessageStore = PinnedMessageStore()
    /// Preview-row tap (om-linkpreview passthrough).
    var onOpenLink: (URL) -> Void = { LinkPreviewOpen.default($0) }
    @StateObject private var scroll = ChatScrollModel()
    /// Look-ahead image prefetch (om-imgpreload): shared across chats
    /// (cache keys are URL+message, so fills dedupe naturally).
    @ObservedObject private var preload = ImagePreloadStore.shared

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Pinned strip (om-pinmessages): pinned to the top of the
                // timeline (never scrolls away). Tap jumps to the bubble.
                PinnedStripView(
                    rows: pins.rows(for: store.chatID, messages: store.messages),
                    onJump: { jumpToPin(proxy, id: $0) },
                    onUnpin: { pins.unpin(chatID: store.chatID, messageID: $0) })
                DietSeamH()
                ZStack(alignment: .bottom) {
                    ScrollView {
                    LazyVStack(alignment: .leading, spacing: DietSpace.sm) {
                        pagingSentinel
                        loadMoreRow
                        if store.loading, store.messages.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small)
                                Text("Loading recent messages…")
                                    .font(DietType.caption1)
                                    .foregroundStyle(DietColor.textSecondaryColor)
                                Spacer()
                            }
                            .padding(.vertical, DietSpace.xl)
                        } else if store.messages.isEmpty, !store.loading {
                            if let err = store.error {
                                DietEmptyState(
                                    systemImage: "wifi.exclamationmark",
                                    title: "Couldn't load messages",
                                    message: err,
                                    actionLabel: "Try Again",
                                    action: { store.retryOpen() })
                            } else {
                                DietEmptyState(
                                    systemImage: "bubble.left.and.bubble.right",
                                    title: "No messages yet",
                                    message: "Start the conversation below — your message appears here.")
                            }
                        }
                        ForEach(sections, id: \.key) { section in
                            DietDaySeparator(section.label)
                            ForEach(section.messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    failed: store.failedIDs.contains(msg.id),
                                    highlightName: store.ownDisplayName,
                                    quoted: store.quotedParent(for: msg),
                                    onRetry: { _ = store.retry(id: msg.id) },
                                    onReact: { store.toggleReaction(messageID: msg.id, emoji: $0) },
                                    onForward: { onForward(msg) },
                                    onReply: { store.beginReply(to: msg) },
                                    onEdit: { onEdit(msg) },
                                    onDelete: { onDelete(msg) },
                                    sharedFiles: sharedFiles,
                                    onOpenDoc: onOpenDoc,
                                    isRead: store.chatID.map {
                                        receipts.isOwnRead(
                                            chatID: $0, messageID: msg.id,
                                            messages: store.messages)
                                    } ?? false,
                                    onOpenLink: onOpenLink,
                                    isPinned: pins.isPinned(
                                        chatID: store.chatID, messageID: msg.id),
                                    onTogglePin: {
                                        pins.toggle(chatID: store.chatID, message: msg)
                                    }
                                )
                                .id(msg.id)
                                .onAppear {
                                    scroll.visibleIDs.insert(msg.id)
                                    noteVisible()
                                }
                                .onDisappear {
                                    scroll.visibleIDs.remove(msg.id)
                                    noteVisible()
                                }
                            }
                        }
                        // Bottom sentinel: on screen ⇔ viewport hugs the
                        // tail. Dwell marks the read frontier (kills the
                        // pill) and sends the read position; leaving
                        // cancels settle (no yank races).
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                scroll.noteBottomDwell(tailID: store.messages.last?.id)
                                sendReadPositionIfViewingLatest()
                            }
                            .onDisappear {
                                scroll.noteLeftBottom()
                            }
                        // Typing row (om-typing): who is typing in the
                        // open thread, only while indicators are live.
                        if let line = typing.line(chatID: store.chatID) {
                            TypingIndicatorView(line: line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, DietSpace.xs)
                        }
                    }
                    .padding(DietSpace.md)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.messages.count) { handleMessagesChanged(proxy) }
                .onChange(of: store.loading) { handleLoadingChanged(proxy) }
                .onAppear {
                    store.openIfNeeded()
                    scroll.lastSeenID = store.messages.last?.id
                    scroll.lastReadID = store.messages.last?.id
                    if let target = Self.scrollTarget(args: CommandLine.arguments) {
                        scrollTo(proxy, id: target)
                    } else {
                        settleToBottom(proxy)
                    }
                    noteVisible()
                    // Shot hook: --show-picker pops the more-picker
                    // on the first reacted bubble (or the first
                    // bubble). Messages arrive after open, so the id
                    // resolves at fire time with a few retries.
                    if CommandLine.arguments.contains("--show-picker") {
                        Self.postPickerShot(store: store, tries: 8)
                    }
                }
                if let action = bottomAction {
                    switch action {
                    case .pill(let title):
                        Button { jumpTap(proxy) } label: {
                            HStack(spacing: DietSpace.xs) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text(title)
                                    .font(DietType.caption1).bold()
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, DietSpace.sm + DietSpace.xs)
                            .padding(.vertical, DietSpace.xs)
                            .background(Color.accentColor, in: Capsule())
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Jump to latest messages")
                        .padding(.bottom, DietSpace.sm)
                    case .jump:
                        Button { jumpTap(proxy) } label: {
                            HStack(spacing: DietSpace.xs) {
                                Image(systemName: "arrow.down.circle")
                                Text("Jump to latest")
                                    .font(DietType.caption1).bold()
                            }
                            .foregroundStyle(DietColor.textPrimaryColor)
                            .padding(.horizontal, DietSpace.sm + DietSpace.xs)
                            .padding(.vertical, DietSpace.xs)
                            .background(DietColor.wellColor, in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(DietColor.dividerColor, lineWidth: 1))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Jump to latest messages")
                        .padding(.bottom, DietSpace.sm)
                    }
                    }
                }
            }
        }
    }

    private var sections: [MessageRender.DaySection] {
        MessageRender.daySections(store.messages)
    }

    private var unseen: Int {
        scroll.unseenCount(messages: store.messages)
    }

    private var bottomAction: BottomAction? {
        ScrollPolicy.bottomAction(unseen: unseen, nearBottom: scroll.nearBottom)
    }

    /// Top reach sentinel (paging primary): a persistent marker above
    /// the load row. Appearing fires one armed+debounced page;
    /// disappearing re-arms. Unlike the old button/spinner onAppear, the
    /// sentinel never swaps on load state, so prepend rebuilds cannot
    /// refire it — each page needs a genuine leave-and-return excursion.
    private var pagingSentinel: some View {
        Color.clear
            .frame(height: 1)
            .onAppear { fireAutoLoadMore() }
            .onDisappear { scroll.armPaging() }
    }

    private var loadMoreRow: some View {
        Group {
            if store.loadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Loading older messages…")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Spacer()
                }
            } else if store.canLoadMore {
                // Explicit tap fallback: the sentinel above auto-fires on
                // genuine reach-top; the tap covers readers whose sentinel
                // never trips. Each tap loads one lazy day-chunk.
                Button("Load older messages") { fireTapLoadMore() }
                    .buttonStyle(.dietSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Auto paging (primary): armed + debounced. Records the fallback
    /// anchor, then loads. Disarms on fire, so prepend/rebuild onAppear
    /// refires collapse until the reader leaves the top again.
    private func fireAutoLoadMore() {
        guard store.canLoadMore else { return }
        guard scroll.shouldAutoFireLoadMore() else { return }
        scroll.prePrependFirstID = store.messages.first?.id
        store.loadMore()
    }

    /// Explicit tap (fallback): debounced, needs no arm. Disarms on fire
    /// so the tap's own prepend rebuild cannot auto-chain.
    private func fireTapLoadMore() {
        guard store.canLoadMore else { return }
        guard scroll.shouldTapLoadMore() else { return }
        scroll.prePrependFirstID = store.messages.first?.id
        store.loadMore()
    }

    /// Visibility changed (appear / disappear / history / new mail):
    /// reschedule the image-prefetch window (om-imgpreload) so bytes
    /// land before their bubbles scroll into view.
    private func noteVisible() {
        preload.update(messages: store.messages, visibleIDs: scroll.visibleIDs)
    }

    /// Tail advance → follow or pill; stable tail + moved count →
    /// prepended history (or same-tail refresh) → hold first-visible.
    /// (A prepend landing in the SAME update as an append takes the
    /// follow/pill path; the anchor only holds pure prepends.)
    private func handleMessagesChanged(_ proxy: ScrollViewProxy) {
        switch scroll.consumeTail(
            currentTailID: store.messages.last?.id,
            isOwnTail: store.messages.last?.isOwn ?? false)
        {
        case .follow:
            scrollToBottom(proxy)
            sendReadPositionIfViewingLatest()
        case .pill:
            break // the pill absorbs it (unseen derives from lastReadID)
        case .none:
            let anchor = scroll.firstVisibleID(in: store.messages)
                ?? scroll.prePrependFirstID
            if let anchor {
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
        noteVisible()
    }

    /// History just landed: restart the settle landing (guarded by
    /// near-bottom so a reader who scrolled during load keeps place).
    private func handleLoadingChanged(_ proxy: ScrollViewProxy) {
        if !store.loading, scroll.nearBottom {
            scroll.lastSeenID = store.messages.last?.id
            scroll.lastReadID = store.messages.last?.id
            settleToBottom(proxy)
            sendReadPositionIfViewingLatest()
        }
    }

    /// Send the read position when the viewport hugs the tail (viewing
    /// latest). Scrolled-up readers never send; demo records locally.
    private func sendReadPositionIfViewingLatest() {
        guard scroll.nearBottom else { return }
        receipts.sendReadPosition(
            chatID: store.chatID, latestID: store.messages.last?.id,
            localOnly: store.isDemo)
    }

    private func jumpTap(_ proxy: ScrollViewProxy) {
        scroll.jumpToLatest(tailID: store.messages.last?.id)
        scrollToBottom(proxy)
        sendReadPositionIfViewingLatest()
    }

    /// Strip tap (om-pinmessages): jump to the pinned bubble when it is
    /// in the loaded window; missing bubbles stay put (never conjure).
    private func jumpToPin(_ proxy: ScrollViewProxy, id: String) {
        guard PinnedMessages.jumpTarget(pinID: id, messages: store.messages) != nil else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
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

    /// --show-picker driver: resolve the target bubble once messages
    /// exist, then ask its anchor to open the more-picker.
    private static func postPickerShot(store: ConversationStore, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let id = store.messages.first(where: { !$0.reactions.isEmpty })?.id
                ?? store.messages.first?.id
            if let id {
                NotificationCenter.default.post(
                    name: ReactionMenuAnchorView.shotPickerNote, object: id)
            } else if tries > 1 {
                postPickerShot(store: store, tries: tries - 1)
            }
        }
    }

    /// Shot hook: `--scroll-to <message-id>` lands the initial scroll
    /// on that bubble (scroll-state shots) instead of the tail.
    /// Unknown ids are ignored (ScrollViewProxy.scrollTo is a no-op).
    static func scrollTarget(args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--scroll-to"), i + 1 < args.count else { return nil }
        let id = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private func scrollTo(_ proxy: ScrollViewProxy, id: String) {
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// Initial land + timed re-asserts while the reader stays near the
    /// bottom. Rows grow as images resolve, so one scroll lands short
    /// (short-land); each pass re-reads live `nearBottom`, and leaving
    /// the bottom cancels the task outright.
    private func settleToBottom(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy, animated: false)
        scroll.cancelSettle()
        scroll.settleTask = Task { @MainActor in
            var waited: TimeInterval = 0
            for step in ScrollPolicy.settleDelays {
                let nanos = UInt64(max(0, step - waited) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                waited = step
                guard !Task.isCancelled else { return }
                if scroll.nearBottom { scrollToBottom(proxy, animated: false) }
            }
        }
    }
}
