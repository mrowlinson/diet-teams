// ChatListSidebar.swift — SwiftUI sidebar: chats + loading/empty/error states.
import DietDesign
import OstMacCore
import SwiftUI

/// Sidebar list of chats. Selection writes through to `model.selectedChatID`
/// for the conversation lane to consume.
public struct ChatListSidebar: View {
    @ObservedObject private var model: ChatListViewModel
    @ObservedObject private var presence: PresenceStore
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var mentions: MentionStore
    @State private var searchText = ""
    @State private var mentionsOnly = false
    /// Leave/block confirm targets (om-leave-block, native alerts below).
    @State private var pendingLeave: ChatItem?
    @State private var pendingBlock: ChatItem?
    /// Last leave attempt (error-alert Retry re-runs it).
    @State private var lastLeaveID: String?

    public init(
        model: ChatListViewModel, presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        mentions: MentionStore = MentionStore(),
        initialFilter: String = ""
    ) {
        self.model = model
        self.presence = presence
        self.unread = unread
        self.mentions = mentions
        _searchText = State(initialValue: initialFilter)
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading chats…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No chats",
                    message: "Your Teams conversations will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load chats",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedList
                    .transition(.opacity)
            }
        }
        // System-default crossfade between content states (the loaded
        // list lands softly instead of popping). Standard SwiftUI only.
        .animation(.default, value: model.state)
        // Native leave confirmation (om-leave-block).
        .alert(
            "Leave “\(pendingLeave?.name ?? "this chat")”?",
            isPresented: leaveConfirmShown, presenting: pendingLeave
        ) { chat in
            Button("Leave Chat", role: .destructive) { confirmLeave(chat) }
            Button("Cancel", role: .cancel) { pendingLeave = nil }
        } message: { _ in
            Text("You’ll stop receiving messages from this chat. You can’t rejoin on your own.")
        }
        // Native block confirmation (om-leave-block).
        .alert(
            "Block “\(pendingBlock?.name ?? "this user")”?",
            isPresented: blockConfirmShown, presenting: pendingBlock
        ) { chat in
            Button("Block User", role: .destructive) { confirmBlock(chat) }
            Button("Cancel", role: .cancel) { pendingBlock = nil }
        } message: { _ in
            Text("You won’t receive messages or notifications from this user. Manage blocked users in Settings.")
        }
        // Leave failure (om-leave-block): Retry re-runs, Cancel clears.
        .alert("Couldn’t Leave Chat", isPresented: leaveErrorShown) {
            Button("Retry") { retryLeave() }
            Button("Cancel", role: .cancel) { dismissLeaveError() }
        } message: {
            Text(model.leaveError ?? "Unknown error")
        }
    }

    /// Confirm bindings: shown while a target is armed.
    private var leaveConfirmShown: Binding<Bool> {
        Binding(
            get: { pendingLeave != nil },
            set: { if !$0 { pendingLeave = nil } })
    }

    private var blockConfirmShown: Binding<Bool> {
        Binding(
            get: { pendingBlock != nil },
            set: { if !$0 { pendingBlock = nil } })
    }

    /// Error alert binding: shown while the model holds a leave error.
    private var leaveErrorShown: Binding<Bool> {
        Binding(
            get: { model.leaveError != nil },
            set: { if !$0 { dismissLeaveError() } })
    }

    /// Confirmed leave: run the model's flow (row drops on success,
    /// error alert on failure — never a list refresh).
    private func confirmLeave(_ chat: ChatItem) {
        pendingLeave = nil
        lastLeaveID = chat.id
        Task { await model.leave(chatID: chat.id) }
    }

    /// Confirmed block: record + drop the row (synchronous, local-only).
    private func confirmBlock(_ chat: ChatItem) {
        pendingBlock = nil
        model.block(chatID: chat.id)
    }

    /// Re-run the failed leave (keeps the alert up on repeat failure).
    private func retryLeave() {
        guard let id = lastLeaveID else {
            dismissLeaveError()
            return
        }
        Task { await model.leave(chatID: id) }
    }

    /// Dismiss the leave error.
    private func dismissLeaveError() {
        model.clearLeaveError()
        lastLeaveID = nil
    }

    private var loadedList: some View {
        // Text filter first, mentions filter second: both preserve
        // order (filtering never re-sorts — pin-top owns the comparator
        // via displayChats).
        var visible = ChatListFormat.filter(model.displayChats, query: searchText)
        if mentionsOnly {
            visible = ChatListFormat.filterMentions(visible, mentionedIDs: mentions.mentionedIDs)
        }
        let queryBlank = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            DietSearchField("Filter chats", text: $searchText)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            DietSeamH()
            mentionsRow
            DietSeamH()
            if visible.isEmpty, mentionsOnly, queryBlank {
                DietEmptyState(
                    systemImage: "at",
                    title: "No mentions",
                    message: "Threads that mention you appear here.",
                    actionLabel: "Show all chats",
                    action: { mentionsOnly = false })
            } else if visible.isEmpty, !queryBlank {
                DietEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No chats match \"\(searchText)\".",
                    actionLabel: "Clear search",
                    action: { searchText = "" })
            } else {
                List(selection: $model.selectedChatID) {
                    // Explicit row identity: rows survive reorder bursts
                    // without content/position mismatch (stable ids).
                    ForEach(visible, id: \.id) { chat in
                        ChatRow(
                            chat: chat,
                            peerAvailability: chat.is_group ? nil : .some(presence.availabilityForChat(chat.id)),
                            leaving: model.leavingIDs.contains(chat.id)
                        )
                        .tag(chat.id)
                        .unreadBadge(unread.count(for: chat.id))
                        .modifier(ChatRowLeaveBlockMenu(
                            model: model, chat: chat,
                            pendingLeave: $pendingLeave, pendingBlock: $pendingBlock))
                    }
                }
                .listStyle(.sidebar)
                // System-default row animation for bubble-to-top moves,
                // inserts, deletes, and filter changes. Keyed on row ids
                // only, so in-place preview refreshes never shimmer the
                // list. Standard SwiftUI only (no custom drivers).
                .animation(.default, value: visible.map(\.id))
            }
        }
    }

    /// Mentions filter row (om-mentions): stable id `mentions`. Tapping
    /// toggles the mentioning-threads filter; the count names the
    /// flagged threads. Always present (stable for shots/tests), muted
    /// at zero. Client-side only — never refetches the list.
    private var mentionsRow: some View {
        Button {
            mentionsOnly.toggle()
        } label: {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: mentionsOnly ? "at.circle.fill" : "at.circle")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(mentionsOnly ? Color.accentColor : DietColor.textSecondaryColor)
                Text("Mentions")
                    .font(DietType.headline)
                    .foregroundStyle(mentionsOnly ? DietColor.textPrimaryColor : DietColor.textSecondaryColor)
                Spacer()
                if mentions.count > 0 {
                    Text("\(mentions.count)")
                        .font(DietType.captionMono)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            .contentShape(Rectangle())
            .background(mentionsOnly ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .id("mentions")
        .accessibilityIdentifier("mentions")
        .help("Show only threads that mention you")
    }
}

/// Row right-click menu (om-leave-block): one top-level item — group
/// chats offer Leave, 1:1 chats offer Block. Synthetic rows (Mentions,
/// Notifications) get no menu. In-flight leaves disable their item.
private struct ChatRowLeaveBlockMenu: ViewModifier {
    @ObservedObject var model: ChatListViewModel
    let chat: ChatItem
    @Binding var pendingLeave: ChatItem?
    @Binding var pendingBlock: ChatItem?

    func body(content: Content) -> some View {
        if PinnedChats.isSynthetic(chat.id) {
            content
        } else {
            content.contextMenu {
                if chat.is_group {
                    Button("Leave Chat…") { pendingLeave = chat }
                        .disabled(model.leavingIDs.contains(chat.id))
                } else {
                    Button("Block User…") { pendingBlock = chat }
                }
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatItem
    /// Chatmate availability for 1:1 chats. Outer nil = group (no dot);
    /// inner nil = unknown (no dot, fail closed).
    var peerAvailability: String?? = nil
    /// Leave call in flight: a spinner replaces the preview time.
    var leaving: Bool = false

    private var dietPresence: DietPresence? {
        guard let outer = peerAvailability else { return nil }
        return DietPresence(teamsAvailability: outer)
    }

    var body: some View {
        HStack(alignment: .center, spacing: DietSpace.sm) {
            DietAvatar(
                chat.name, presence: dietPresence,
                size: DietSize.avatarMD)
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.name)
                        .font(DietType.headline)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(1)
                    Spacer()
                    if leaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Leaving chat")
                    } else {
                        Text(ChatListFormat.previewTime(chat.last_message_time))
                            .font(DietType.captionMono)
                            .foregroundStyle(DietColor.textTertiaryColor)
                    }
                }
                Text(previewText)
                    .font(DietType.subheadline)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, DietSpace.xs)
    }

    private var previewText: String {
        let line = ChatListFormat.previewLine(
            sender: chat.last_message_sender,
            preview: chat.last_message_preview)
        return line.isEmpty ? "No messages" : line
    }
}

/// Native list badge for unread counts (om-notifbadge): the system
/// `.badge(_:)` when positive, no badge at zero. Shared by the chats
/// list and the teams browser (same module).
extension View {
    @ViewBuilder
    func unreadBadge(_ count: Int) -> some View {
        if count > 0 {
            badge(count)
        } else {
            self
        }
    }
}
