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
    /// New-channel sheet visibility (om-h3-create).
    @State private var showCreate = false
    /// New-team sheet visibility (om-jf-teamcreate).
    @State private var showTeamCreate = false
    /// Join-sheet visibility + the typed team id.
    @State private var showJoin = false
    @State private var joinTeamID = ""

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
                    message: "Teams you join will appear here.",
                    actionLabel: "Join a team",
                    action: { showJoin = true })
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
        .sheet(isPresented: $showJoin) {
            JoinTeamSheet(
                teamID: $joinTeamID,
                joining: !model.joiningIDs.isEmpty,
                error: model.joinError,
                onJoin: {
                    let id = joinTeamID
                    Task {
                        await model.join(teamID: id)
                        if model.joinError == nil {
                            joinTeamID = ""
                            showJoin = false
                        }
                    }
                })
        }
    }

    private var loadedList: some View {
        let visible = TeamsViewModel.filtered(model.teams, query: searchText)
        let filtering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: DietSpace.xs) {
                DietSearchField("Filter teams", text: $searchText)
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New channel")
                .help("Create a channel in one of your teams")
                Button {
                    showJoin = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .buttonStyle(DietSecondaryButtonStyle())
                .accessibilityLabel("Join a team")
                .help("Join a team by ID")
                Button {
                    showTeamCreate = true
                } label: {
                    Image(systemName: "person.3.fill")
                }
                .buttonStyle(DietSecondaryButtonStyle())
                .accessibilityLabel("New team")
                .help("Create a team")
            }
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
                            Group {
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
                            }
                            // Insertion is opacity-only + clipped: labels hold
                            // their slots and never paint outside them.
                            // (Chevron toggles step instantly — no animation
                            // on disclosure state, see below — so nothing
                            // interpolates and nothing slides.)
                            .transition(.opacity)
                            .clipped()
                        } label: {
                            TeamHeader(name: team.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                // No animation on disclosure state: chevron toggles step
                // instantly to their final slots — labels stay put instead
                // of sliding through intermediate positions (verified
                // frame-by-frame). The sidebar outline drives row
                // expansion natively and ignores .opacity transitions, so
                // any animation here can only slide, never fade — stepped
                // is the no-slide fix. Filter keystrokes keep the
                // system-default animation (rows match/unmatch plus
                // pinned-open expansion). Standard SwiftUI only.
                .animation(.default, value: searchText)
            }
        }
        .sheet(isPresented: $showCreate) {
            ChannelCreateSheet(model: model) {
                showCreate = false
            }
        }
        .sheet(isPresented: $showTeamCreate) {
            TeamCreateSheet(model: model) {
                showTeamCreate = false
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
        // Leading anchor + clip: the header label holds its slot and
        // clips during expand/collapse instead of drifting.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.vertical, DietSpace.xs)
    }
}

/// Join-by-ID sheet: paste a team id (GUID), Join self-enrolls via
/// core `ostmac_team_join`. Stays open on failure showing `error`.
struct JoinTeamSheet: View {
    @Binding var teamID: String
    let joining: Bool
    let error: String?
    let onJoin: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: DietSpace.sm) {
            Text("Join a team")
                .font(DietType.title3)
                .foregroundStyle(DietColor.textPrimaryColor)
            Text("Paste the team ID. You join as a member.")
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
            TextField("Team ID", text: $teamID)
                .textFieldStyle(.roundedBorder)
                .disabled(joining)
            if let error {
                Text(error)
                    .font(DietType.callout)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
            }
            HStack(spacing: DietSpace.xs) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(DietSecondaryButtonStyle())
                    .disabled(joining)
                Button(joining ? "Joining…" : "Join") { onJoin() }
                    .buttonStyle(DietPrimaryButtonStyle())
                    .disabled(joining || teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DietSpace.md)
        .frame(minWidth: 320)
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
            // Leading anchor + clip: channel labels fade in place
            // (see disclosure content transition above), never slide.
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .padding(.vertical, DietSpace.xs)
        }
        .buttonStyle(.plain)
    }
}
