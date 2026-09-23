// ChatTimelineView.swift — om-scroll: message timeline with follow/pill,
// prepend anchoring, debounced paging, and settle re-asserts.
//
// Extracted from ConversationView so the scroll state (ChatScrollModel)
// is owned per chat: the parent `.id()`s this view by chatID, giving
// each chat a fresh model, sentinel, and settle generation.
import DietDesign
import SwiftUI

struct ChatTimelineView: View {
    @ObservedObject var store: ConversationStore
    var onForward: (ChatMessage) -> Void = { _ in }
    @StateObject private var scroll = ChatScrollModel()

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DietSpace.sm) {
                        loadMoreRow
                        if store.messages.isEmpty, !store.loading {
                            DietEmptyState(
                                systemImage: "bubble.left.and.bubble.right",
                                title: "No messages yet",
                                message: "Start the conversation below — your message appears here.")
                        }
                        ForEach(sections, id: \.key) { section in
                            DietDaySeparator(section.label)
                            ForEach(section.messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    failed: store.failedIDs.contains(msg.id),
                                    quoted: store.quotedParent(for: msg),
                                    onRetry: { _ = store.retry(id: msg.id) },
                                    onReact: { store.toggleReaction(messageID: msg.id, emoji: $0) },
                                    onForward: { onForward(msg) },
                                    onReply: { store.beginReply(to: msg) }
                                )
                                .id(msg.id)
                                .onAppear { scroll.visibleIDs.insert(msg.id) }
                                .onDisappear { scroll.visibleIDs.remove(msg.id) }
                            }
                        }
                        // Bottom sentinel: on screen ⇔ viewport hugs the
                        // tail. Dwell marks the read frontier (kills the
                        // pill); leaving cancels settle (no yank races).
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                scroll.nearBottom = true
                                scroll.lastReadID = store.messages.last?.id
                            }
                            .onDisappear {
                                scroll.nearBottom = false
                                scroll.cancelSettle()
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
                    settleToBottom(proxy)
                }
                if let title = ScrollPolicy.pillTitle(unseen: unseen) {
                    Button { pillTap(proxy) } label: {
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
                }
            }
        }
    }

    private var sections: [MessageRender.DaySection] {
        MessageRender.daySections(store.messages)
    }

    private var unseen: Int {
        ScrollPolicy.unseenCount(messages: store.messages, after: scroll.lastReadID)
    }

    private var loadMoreRow: some View {
        Group {
            if store.loadingMore {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            } else if store.canLoadMore {
                Button("Load older messages") { fireLoadMore() }
                    .buttonStyle(.dietSecondary)
                    .frame(maxWidth: .infinity)
                    .onAppear { fireLoadMore() }
            }
        }
    }

    /// Debounced top paging (auto + tap share one gate): records the
    /// fallback anchor, then loads. Rapid onAppear refires collapse.
    private func fireLoadMore() {
        guard scroll.shouldFireLoadMore() else { return }
        scroll.prePrependFirstID = store.messages.first?.id
        store.loadMore()
    }

    /// Tail advance → follow or pill; stable tail + moved count →
    /// prepended history (or same-tail refresh) → hold first-visible.
    /// (A prepend landing in the SAME update as an append takes the
    /// follow/pill path; the anchor only holds pure prepends.)
    private func handleMessagesChanged(_ proxy: ScrollViewProxy) {
        let current = store.messages.last?.id
        if current != scroll.lastSeenID {
            scroll.lastSeenID = current
            if ScrollPolicy.shouldFollow(
                nearBottom: scroll.nearBottom,
                isOwnTail: store.messages.last?.isOwn ?? false)
            {
                scroll.lastReadID = current
                scrollToBottom(proxy)
            }
            // Else: the pill absorbs it (unseen derives from lastReadID).
        } else {
            let anchor = scroll.firstVisibleID(in: store.messages)
                ?? scroll.prePrependFirstID
            if let anchor {
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    /// History just landed: restart the settle landing (guarded by
    /// near-bottom so a reader who scrolled during load keeps place).
    private func handleLoadingChanged(_ proxy: ScrollViewProxy) {
        if !store.loading, scroll.nearBottom {
            scroll.lastSeenID = store.messages.last?.id
            scroll.lastReadID = store.messages.last?.id
            settleToBottom(proxy)
        }
    }

    private func pillTap(_ proxy: ScrollViewProxy) {
        scroll.lastReadID = store.messages.last?.id
        scroll.nearBottom = true
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
