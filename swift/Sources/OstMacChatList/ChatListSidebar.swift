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
    @ObservedObject private var rules: RulesStore
    @State private var searchText = ""
    @State private var mentionsOnly = false
    @State private var showHidden = false

    public init(
        model: ChatListViewModel, presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        mentions: MentionStore = MentionStore(),
        rules: RulesStore = RulesStore(),
        initialFilter: String = ""
    ) {
        self.model = model
        self.presence = presence
        self.unread = unread
        self.mentions = mentions
        self.rules = rules
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
    }

    private var loadedList: some View {
        // Hidden filter first, text second, mentions third: all preserve
        // order (filtering never re-sorts — pin-top owns the comparator
        // via displayChats). Client-side only — never refetches the list.
        var visible = ChatListFormat.filterHidden(
            model.displayChats, hiddenIDs: rules.config.hiddenChatIDs,
            showHidden: showHidden)
        visible = ChatListFormat.filter(visible, query: searchText)
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
            hiddenRow
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
                            isPinned: model.isPinned(chat.id),
                            peerAvailability: chat.is_group ? nil : .some(presence.availabilityForChat(chat.id))
                        )
                        .tag(chat.id)
                        .unreadBadge(unread.count(for: chat.id))
                        // Wave G row menu: one native menu, top-level
                        // items only (never a submenu). Real threads only —
                        // synthetic pinned rows are app UI, not threads.
                        // Badge updates in place, list never refetches.
                        .contextMenu {
                            if !PinnedChats.isSynthetic(chat.id) {
                                if model.isPinned(chat.id) {
                                    Button("Unpin", systemImage: "pin.slash") {
                                        model.unpin(chat.id)
                                    }
                                } else {
                                    Button("Pin", systemImage: "pin") {
                                        model.pin(chat.id)
                                    }
                                }
                                if unread.count(for: chat.id) > 0 {
                                    Button("Mark as Read") {
                                        unread.markRead(chatID: chat.id)
                                    }
                                } else {
                                    Button("Mark as Unread") {
                                        unread.markUnread(chatID: chat.id)
                                    }
                                }
                                // Mute absolute (no banners, no unread,
                                // mentions incl); hide drops row until Show
                                // hidden restores it.
                                Button(rules.isMuted(chatID: chat.id) ? "Unmute" : "Mute") {
                                    rules.setMuted(chatID: chat.id, muted: !rules.isMuted(chatID: chat.id))
                                }
                                Button(rules.isHidden(chatID: chat.id) ? "Unhide" : "Hide") {
                                    rules.setHidden(chatID: chat.id, hidden: !rules.isHidden(chatID: chat.id))
                                }
                            }
                        }
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

    /// Show-hidden row (om-mute-hide): stable id `show-hidden`. Tapping
    /// reveals hidden threads (hidden filter bypassed); tapping again
    /// re-hides them. Restore path: reveal, then Unhide from the row's
    /// context menu. Always present (stable for shots/tests), muted when
    /// off. Client-side only — never refetches the list. No count shown
    /// (counters live in Diagnostics only).
    private var hiddenRow: some View {
        Button {
            showHidden.toggle()
        } label: {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: showHidden ? "eye.fill" : "eye")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(showHidden ? Color.accentColor : DietColor.textSecondaryColor)
                Text(showHidden ? "Showing hidden" : "Show hidden")
                    .font(DietType.headline)
                    .foregroundStyle(showHidden ? DietColor.textPrimaryColor : DietColor.textSecondaryColor)
                Spacer()
            }
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            .contentShape(Rectangle())
            .background(showHidden ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .id("show-hidden")
        .accessibilityIdentifier("show-hidden")
        .help("Show hidden threads to restore them")
    }
}

struct ChatRow: View {
    let chat: ChatItem
    /// User-pinned rows show a pin glyph by the timestamp.
    var isPinned: Bool = false
    /// Chatmate availability for 1:1 chats. Outer nil = group (no dot);
    /// inner nil = unknown (no dot, fail closed).
    var peerAvailability: String?? = nil

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
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: DietSize.iconSM))
                            .foregroundStyle(DietColor.textTertiaryColor)
                            .accessibilityLabel("Pinned")
                    }
                    Text(ChatListFormat.previewTime(chat.last_message_time))
                        .font(DietType.captionMono)
                        .foregroundStyle(DietColor.textTertiaryColor)
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
