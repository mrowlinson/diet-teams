// SidebarColumn.swift — sidebar column: Chats list + Teams browser switcher.
import DietDesign
import OstMacCore
import SwiftUI

/// Sidebar column hosting the chats list, the teams/channels browser,
/// the reminders browser, the planner boards browser, the recordings
/// browser, and the shifts week grid behind a segmented switcher.
/// Channel taps open as conversations via
/// `onOpenChannel` (channel id + "Team > #channel" display name).
///
/// The switcher header is exactly `DietSize.toolbar` tall with a system
/// seam below, so it sits on the same pixel row as the content column's
/// `DietHeaderBar` seam (single divider language app-wide).
public struct SidebarColumn: View {
    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var teams: TeamsViewModel
    @ObservedObject private var reminders: RemindersViewModel
    @ObservedObject private var planner: PlannerViewModel
    @ObservedObject private var recordings: RecordingsViewModel
    @ObservedObject private var shifts: ShiftsStore
    @ObservedObject private var presence: PresenceStore
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var mentions: MentionStore
    @ObservedObject private var rules: RulesStore
    private let openChatID: String?
    private let initialFilter: String
    private let channelCreateOpen: Bool
    private let teamCreateOpen: Bool
    /// d1-folders shot hook: preselected folder (nil = All chats).
    private let initialFolderID: String?
    /// d1-folders shot hook: manager sheet open at launch.
    private let folderManageOpen: Bool
    /// d1-folders shot hook: rule id with its editor expanded.
    private let initialEditingRuleID: String?
    private let onOpenChannel: (String, String) -> Void
    @State private var section: SidebarSection
    /// Reduce Motion (om-a1-motion): section flips cut, never crossfade.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        chats: ChatListViewModel, teams: TeamsViewModel,
        reminders: RemindersViewModel, planner: PlannerViewModel,
        recordings: RecordingsViewModel, shifts: ShiftsStore,
        presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        mentions: MentionStore = MentionStore(),
        rules: RulesStore = RulesStore(),
        openChatID: String? = nil,
        initialSection: SidebarSection = .chats,
        initialFilter: String = "",
        channelCreateOpen: Bool = false,
        teamCreateOpen: Bool = false,
        initialFolderID: String? = nil,
        folderManageOpen: Bool = false,
        initialEditingRuleID: String? = nil,
        onOpenChannel: @escaping (String, String) -> Void
    ) {
        self.chats = chats
        self.teams = teams
        self.reminders = reminders
        self.planner = planner
        self.recordings = recordings
        self.shifts = shifts
        self.presence = presence
        self.unread = unread
        self.mentions = mentions
        self.rules = rules
        self.openChatID = openChatID
        self.initialFilter = initialFilter
        self.channelCreateOpen = channelCreateOpen
        self.teamCreateOpen = teamCreateOpen
        self.initialFolderID = initialFolderID
        self.folderManageOpen = folderManageOpen
        self.initialEditingRuleID = initialEditingRuleID
        _section = State(initialValue: initialSection)
        self.onOpenChannel = onOpenChannel
    }

    public var body: some View {
        VStack(spacing: 0) {
            DietSegmentedPicker("Section", selection: $section)
                .padding(.horizontal, DietSpace.sm)
                .frame(height: DietSize.toolbar)
            DietSeamH()
            switch section {
            case .chats:
                ChatListSidebar(model: chats, presence: presence, unread: unread, mentions: mentions, rules: rules, initialFilter: initialFilter, initialFolderID: initialFolderID, folderManageOpen: folderManageOpen, initialEditingRuleID: initialEditingRuleID)
                    .transition(.opacity)
            case .teams:
                TeamsBrowser(
                    model: teams, openChatID: openChatID, unread: unread,
                    initialFilter: initialFilter,
                    channelCreateOpen: channelCreateOpen,
                    teamCreateOpen: teamCreateOpen,
                    onOpen: onOpenChannel)
                    .transition(.opacity)
            case .reminders:
                RemindersBrowser(model: reminders)
                    .transition(.opacity)
            case .planner:
                PlannerBrowser(model: planner)
                    .transition(.opacity)
            case .recordings:
                RecordingsBrowser(model: recordings)
                    .transition(.opacity)
            case .shifts:
                ShiftsBrowser(model: shifts)
                    .transition(.opacity)
            }
        }
        // System-default crossfade when the segmented switcher flips
        // sections (instant cut under Reduce Motion). Standard
        // SwiftUI only (no custom drivers).
        .animation(DietMotion.gated(reduceMotion: reduceMotion), value: section)
    }
}

public enum SidebarSection: String, CaseIterable {
    case chats = "Chats"
    case teams = "Teams"
    case reminders = "Reminders"
    case planner = "Planner"
    case recordings = "Recordings"
    case shifts = "Shifts"
}
