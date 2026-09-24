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
    /// Collapsed team ids. Empty = all expanded (new teams arrive open).
    @State private var collapsedTeamIDs: Set<String> = []

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

    /// Disclosure state for one team. Filtering pins every visible team
    /// open so matches are never hidden inside a collapsed group.
    /// Pure helper so tests pin the expand/collapse contract.
    public static func isExpanded(teamID: String, collapsed: Set<String>, filtering: Bool) -> Bool {
        if filtering { return true }
        return !collapsed.contains(teamID)
    }

    /// Next collapsed set after toggling one team. Pure helper so tests
    /// pin the per-team toggle (no all-or-nothing side effects).
    public static func toggled(_ collapsed: Set<String>, teamID: String) -> Set<String> {
        var out = collapsed
        if out.contains(teamID) {
            out.remove(teamID)
        } else {
            out.insert(teamID)
        }
        return out
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
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "person.3",
                    title: "No teams",
                    message: "Teams you join will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load teams",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedList
                    .transition(.opacity)
            }
        }
        // System-default crossfade between content states (load lands
        // softly instead of popping). Standard SwiftUI only.
        .animation(.default, value: model.state)
    }

    private var loadedList: some View {
        let visible = TeamsViewModel.filtered(model.teams, query: searchText)
        let filtering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                // Native outline: one DisclosureGroup per team inside a
                // sidebar list (Finder/Mail chevron + animation language).
                List {
                    ForEach(visible) { team in
                        DisclosureGroup(
                            isExpanded: expandedBinding(for: team.id, filtering: filtering)
                        ) {
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
                                        // om-markunread: same native row
                                        // menu as the chats list (top-level
                                        // only). Badge updates in place; the
                                        // browser never refetches.
                                        .contextMenu {
                                            if unread.count(for: channel.id) > 0 {
                                                Button("Mark as Read") {
                                                    unread.markRead(chatID: channel.id)
                                                }
                                            } else {
                                                Button("Mark as Unread") {
                                                    unread.markUnread(chatID: channel.id)
                                                }
                                            }
                                        }
                                }
                            }
                        } label: {
                            TeamHeader(name: team.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                // System-default animation for chevron toggles (value 1)
                // and for filter keystrokes (value 2: rows match/unmatch
                // plus pinned-open expansion). Standard SwiftUI only.
                .animation(.default, value: collapsedTeamIDs)
                .animation(.default, value: searchText)
            }
        }
    }

    /// Per-team disclosure binding. While filtering the getter pins open;
    /// the setter still records intent so clearing the filter lands where
    /// the user left it.
    private func expandedBinding(for teamID: String, filtering: Bool) -> Binding<Bool> {
        Binding(
            get: {
                Self.isExpanded(teamID: teamID, collapsed: collapsedTeamIDs, filtering: filtering)
            },
            set: { wantExpanded in
                if wantExpanded {
                    collapsedTeamIDs.remove(teamID)
                } else {
                    collapsedTeamIDs.insert(teamID)
                }
            }
        )
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
