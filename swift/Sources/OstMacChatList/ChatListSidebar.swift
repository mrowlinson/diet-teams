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
    @State private var searchText = ""

    public init(
        model: ChatListViewModel, presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        initialFilter: String = ""
    ) {
        self.model = model
        self.presence = presence
        self.unread = unread
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
            case .empty:
                DietEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No chats",
                    message: "Your Teams conversations will appear here.")
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load chats",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
            case .loaded:
                loadedList
            }
        }
    }

    private var loadedList: some View {
        let visible = ChatListFormat.filter(model.chats, query: searchText)
        return VStack(spacing: 0) {
            DietSearchField("Filter chats", text: $searchText)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            DietSeamH()
            if visible.isEmpty, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DietEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No chats match \"\(searchText)\".",
                    actionLabel: "Clear search",
                    action: { searchText = "" })
            } else {
                List(selection: $model.selectedChatID) {
                    ForEach(visible) { chat in
                        ChatRow(
                            chat: chat,
                            peerAvailability: chat.is_group ? nil : .some(presence.availabilityForChat(chat.id))
                        )
                        .tag(chat.id)
                        .unreadBadge(unread.count(for: chat.id))
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatItem
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
