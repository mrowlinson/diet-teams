// TeamsBrowser.swift — SwiftUI browser: teams + channels, opens conversations.
import DietDesign
import OstMacCore
import SwiftUI

/// Teams/channels browser. Tapping a channel calls `onOpen` with the
/// channel id + display name; the host opens it as a conversation through
/// the same path as chats (channel ids are conversation ids).
///
/// om-reskin-teams: DietDesign filter + states + rows. The filter is a
/// `DietSearchField` above a `DietSeamH` (same header rhythm as the chats
/// list); loading/empty/error/no-matches are `DietEmptyState`.
public struct TeamsBrowser: View {
    @ObservedObject private var model: TeamsViewModel
    @ObservedObject private var unread: UnreadStore
    private let openChatID: String?
    private let onOpen: (String, String) -> Void
    @State private var searchText = ""

    public init(
        model: TeamsViewModel, openChatID: String? = nil,
        unread: UnreadStore = UnreadStore(),
        initialFilter: String = "",
        onOpen: @escaping (String, String) -> Void
    ) {
        self.model = model
        self.unread = unread
        self.openChatID = openChatID
        _searchText = State(initialValue: initialFilter)
        self.onOpen = onOpen
    }

    /// "Team > #channel" display name for an opened channel.
    /// Pure helper so tests pin the format (DemoData.name must match).
    public static func channelDisplayName(team: String, channel: String) -> String {
        "\(team) > #\(channel)"
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading teams…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                DietEmptyState(
                    systemImage: "person.3",
                    title: "No teams",
                    message: "Teams you join will appear here.")
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load teams",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
            case .loaded:
                loadedList
            }
        }
    }

    private var loadedList: some View {
        let visible = TeamsViewModel.filtered(model.teams, query: searchText)
        return VStack(spacing: 0) {
            DietSearchField("Filter teams", text: $searchText)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            DietSeamH()
            if visible.isEmpty {
                DietEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No teams or channels match \"\(searchText)\".",
                    actionLabel: "Clear search",
                    action: { searchText = "" })
            } else {
                List {
                    ForEach(visible) { team in
                        Section {
                            if team.channels.isEmpty {
                                Text("No channels")
                                    .font(DietType.callout)
                                    .foregroundStyle(DietColor.textSecondaryColor)
                            } else {
                                ForEach(team.channels) { channel in
                                    ChannelRow(
                                        channel: channel,
                                        teamName: team.name,
                                        isOpen: channel.id == openChatID,
                                        onOpen: onOpen)
                                        .unreadBadge(unread.count(for: channel.id))
                                }
                            }
                        } header: {
                            TeamHeader(name: team.name)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

/// Team section header: team avatar + name on Diet type/color.
struct TeamHeader: View {
    let name: String

    var body: some View {
        HStack(spacing: DietSpace.xs) {
            DietAvatar(name, size: DietSize.avatarSM)
            Text(name)
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
                .lineLimit(1)
        }
        .padding(.vertical, DietSpace.xs)
    }
}

struct ChannelRow: View {
    let channel: TeamChannel
    let teamName: String
    let isOpen: Bool
    let onOpen: (String, String) -> Void

    var body: some View {
        Button {
            onOpen(channel.id, TeamsBrowser.channelDisplayName(team: teamName, channel: channel.name))
        } label: {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: "number")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(DietColor.textSecondaryColor)
                Text(channel.name)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .lineLimit(1)
                Spacer()
                if isOpen {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: DietSize.iconMD))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Open")
                }
            }
            .padding(.vertical, DietSpace.xs)
        }
        .buttonStyle(.plain)
    }
}
