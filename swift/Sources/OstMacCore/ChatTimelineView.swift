// ChatTimelineView.swift — om-scroll/om-history/om-editdel/om-react-polish/om-scrollbottom/om-pinmessages/om-hu-polish:
// message timeline with follow/pill, prepend anchoring, armed+debounced
// paging, history loading/error states, edit/delete passthrough, the
// more-picker shot hook, settle re-asserts, a jump-to-latest while
// scrolled up with nothing new, the pinned strip (tap jumps), the
// open-chain progress count, and the capped-window marker.
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
    /// Saved messages (e2-saved): the bubble menu save state.
    @ObservedObject var saved: SavedMessageStore = SavedMessageStore()
    /// Channel context for saves (e2-saved): team/channel ids behind one
    /// chat id (nil pair for plain chats). Injected; default saves bare.
    var savedContext: (String) -> (teamID: String?, channelID: String?) = { _ in (nil, nil) }
    /// Inline translation (e1-translation): per-bubble cached entries.
    @ObservedObject var translations: TranslationStore = TranslationStore()
    /// Preview-row tap (om-linkpreview passthrough).
    var onOpenLink: (URL) -> Void = { LinkPreviewOpen.default($0) }
    @StateObject private var scroll = ChatScrollModel()
    /// Look-ahead image prefetch (om-imgpreload): shared across chats
    /// (cache keys are URL+message, so fills dedupe naturally).
    @ObservedObject private var preload = ImagePreloadStore.shared
    /// Reduce Motion (om-a1-motion): every scrollTo below lands
    /// instantly when set — no animated travel.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Message density (f2-density): row gap + separator padding.
    /// Plain environment value (no per-row store subscription).
    @Environment(\.messageDensity) private var density

    var body: some View {
        // One id index per body-eval (om-s6-renderparse): the strip,
        // quote, and receipt lookups share it instead of scanning the
        // thread per bubble. Same values, O(n) build + O(1) lookups.
        timelineBody(index: MessageIndex(store.messages))
            // On-device translation session (e1-translation, macOS 15+;
            // pass-through below — menus omit Translate there).
            .translationSessionHost(store: translations)
    }

    private func timelineBody(index: MessageIndex) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Pinned strip (om-pinmessages): pinned to the top of the
                // timeline (never scrolls away). Tap jumps to the bubble.
                PinnedStripView(
                    rows: pins.rows(for: store.chatID, messages: store.messages, index: index),
                    onJump: { jumpToPin(proxy, id: $0) },
                    onUnpin: { pins.unpin(chatID: store.chatID, messageID: $0) })
                DietSeamH()
                ZStack(alignment: .bottom) {
                    ScrollView {
                    LazyVStack(alignment: .leading, spacing: density.metrics.rowGap) {
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
                            DietDaySeparator(section.label, compact: density == .compact)
                            ForEach(section.messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    failed: store.failedIDs.contains(msg.id),
                                    highlightName: store.ownDisplayName,
                                    quoted: store.quotedParent(for: msg, in: index),
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
                                            position: index.position)
                                    } ?? false,
                                    onOpenLink: onOpenLink,
                                    isPinned: pins.isPinned(
                                        chatID: store.chatID, messageID: msg.id),
                                    onTogglePin: {
                                        pins.toggle(chatID: store.chatID, message: msg)
                                    },
                                    isSaved: saved.isSaved(
                                        chatID: store.chatID, messageID: msg.id),
                                    onToggleSave: {
                                        let ctx = store.chatID.map { savedContext($0) }
                                        saved.toggle(
                                            chatID: store.chatID,
                                            teamID: ctx?.teamID, channelID: ctx?.channelID,
                                            message: msg)
                                    },
                                    chatID: store.chatID,
                                    onQuoteJump: { jumpToQuote(proxy, id: $0) },
                                    translation: translations.entry(for: msg.id),
                                    onTranslate: {
                                        Task { await translations.toggle(msg) }
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
                        // Typing row (om-typing): who is typing in the
                        // open thread, only while indicators are live.
                        // Above the sentinel (om-fix-scroll): the
                        // sentinel is the true content end.
                        if let line = typing.line(chatID: store.chatID) {
                            TypingIndicatorView(line: line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, DietSpace.xs)
                        }
                        // Bottom sentinel: on screen ⇔ viewport hugs the
                        // tail. Dwell marks the read frontier (kills the
                        // pill) and sends the read position; leaving
                        // cancels settle (no yank races). Laid out LAST
                        // with the trailing inset as part of it
                        // (om-fix-scroll), so scrollToBottom lands on the
                        // exact content end with zero gap.
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, DietSpace.md)
                            .id(ScrollPolicy.bottomSentinelID)
                            .onAppear {
                                scroll.noteBottomDwell(tailID: store.messages.last?.id)
                                sendReadPositionIfViewingLatest()
                            }
                            .onDisappear {
                                scroll.noteLeftBottom()
                            }
                    }
                    .padding([.top, .leading, .trailing], density.metrics.timelineEdge)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.messages.count) { handleMessagesChanged(proxy) }
                .onChange(of: store.loading) { handleLoadingChanged(proxy) }
                // Jump-to-message (om-ja-search): the armed bubble id lands
                // the scroll, then consumes so later mail never yanks.
                .onChange(of: store.jumpTargetID) {
                    guard let target = store.jumpTargetID else { return }
                    scroll.cancelSettle()
                    jumpScroll(proxy, target: target, anchor: .center)
                    store.clearJumpTarget()
                }
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
                    // on the bottom-most reacted bubble (or the last
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
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(A11yLabels.jumpPill(title: title))
                        .help("Jump to latest messages")
                        .padding(.bottom, DietSpace.sm)
                    case .jump:
                        Button { jumpTap(proxy) } label: {
                            HStack(spacing: DietSpace.xs) {
                                Image(systemName: "arrow.down.circle")
                                Text("Jump to latest")
                                    .font(DietType.caption1).bold()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(A11yLabels.jumpPill(title: nil))
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
            if let progress = ScrollPolicy.openProgressTitle(
                loading: store.loading, messageCount: store.messages.count)
            {
                // Open page-chain running with bubbles landed: count the
                // slice so far (om-hu-polish). Before the first publish
                // the centered "Loading recent" block covers it instead.
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Spacer()
                }
            } else if store.loadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Loading older messages…")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Spacer()
                }
            } else if store.canLoadMore {
                // Capped window (om-hu-polish): name the visible slice
                // above the explicit-tap fallback.
                if let marker = ScrollPolicy.showingLastTitle(
                    didLoad: store.didLoad,
                    loading: store.loading || store.loadingMore,
                    messageCount: store.messages.count,
                    hasMoreHistory: store.pageToken != nil,
                    isDemo: store.isDemo)
                {
                    Text(marker)
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // Explicit tap fallback: the sentinel above auto-fires on
                // genuine reach-top; the tap covers readers whose sentinel
                // never trips. Each tap loads one lazy day-chunk.
                Button("Load older messages") { fireTapLoadMore() }
                    .buttonStyle(.bordered)
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
            // Open page-chain prepends skip the anchor hold (single land
            // at chain end); scroll-up pages still hold first-visible.
            guard ScrollPolicy.shouldAnchorPrepend(loading: store.loading) else { break }
            let anchor = scroll.firstVisibleID(in: store.messages)
                ?? scroll.prePrependFirstID
            if let anchor {
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
        noteVisible()
    }

    /// Open chain finished: always land on latest. The chain
    /// prepends skipped their anchor holds, so without this the
    /// viewport can sit parked mid-list on long threads; re-hug the
    /// tail even when the sentinel never tripped during the load.
    private func handleLoadingChanged(_ proxy: ScrollViewProxy) {
        if !store.loading {
            scroll.lastSeenID = store.messages.last?.id
            // Jump-to-message (om-ja-search): an armed target owns the
            // land — the jumpTargetID onChange scrolls to it; the tail
            // land below would yank right back to latest.
            guard store.jumpTargetID == nil else { return }
            scroll.jumpToLatest(tailID: store.messages.last?.id)
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
            self.jumpScroll(proxy, target: id, anchor: .center)
        }
    }

    /// Animated jump scroll, instant under Reduce Motion. Single funnel
    /// for the jump-to-message / pin / quote scrolls.
    private func jumpScroll(
        _ proxy: ScrollViewProxy, target: String, anchor: UnitPoint
    ) {
        if DietMotion.scrollAnimated(requested: true, reduceMotion: reduceMotion) {
            withAnimation { proxy.scrollTo(target, anchor: anchor) }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    /// Quote-strip tap (om-lt2-quotelink): jump to the quoted parent
    /// when it is in the loaded window; evicted ids stay put (the
    /// fallback line never calls this, but the guard keeps live
    /// races safe — eviction between render and tap is a no-op).
    private func jumpToQuote(_ proxy: ScrollViewProxy, id: String) {
        let target = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty,
              store.messages.contains(where: { $0.id == target })
        else { return }
        DispatchQueue.main.async {
            self.jumpScroll(proxy, target: target, anchor: .center)
        }
    }

    /// Exact-bottom landing (om-fix-scroll): targets the bottom
    /// sentinel (true content end), never the tail bubble — targeting
    /// the bubble parks ~1 wheel-click short (sentinel + trailing inset
    /// below the fold). Empty thread → no-op.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let target = ScrollPolicy.bottomTargetID(tailID: store.messages.last?.id) else { return }
        let animate = DietMotion.scrollAnimated(requested: animated, reduceMotion: reduceMotion)
        DispatchQueue.main.async {
            if animate {
                withAnimation { proxy.scrollTo(target, anchor: .bottom) }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    /// --show-picker driver: ask the target bubble's anchor to open
    /// the more-picker. Re-posts until tries run out: the notified
    /// anchor can be a stale copy (SwiftUI replaces representable
    /// views during load), so a late-created anchor catches a later
    /// post. The anchor dedups via isPickerShown.
    private static func postPickerShot(store: ConversationStore, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard tries > 0 else { return }
            // Bottom-most: settle-to-bottom keeps the tail on-screen,
            // and LazyVStack detaches off-screen rows (their anchors
            // have no window, so the picker can never show on them).
            let id = store.messages.last(where: { !$0.reactions.isEmpty })?.id
                ?? store.messages.last?.id
            if let id {
                NotificationCenter.default.post(
                    name: ReactionMenuAnchorView.shotPickerNote, object: id)
            }
            postPickerShot(store: store, tries: tries - 1)
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
