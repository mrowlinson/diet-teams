// SidebarColumn.swift — sidebar column: app rail + section browsers.
import DietDesign
import OstMacCore
import SwiftUI

/// Sidebar column hosting the chats list, the teams/channels browser,
/// the reminders browser, the planner boards browser, the recordings
/// browser, the transcripts browser, and the shifts week grid behind
/// the Teams-like `AppNavRail` (fixed 72pt, native buttons).
/// Channel taps open as conversations via
/// `onOpenChannel` (channel id + "Team > #channel" display name).
///
/// The rail replaces the old 7-tab segmented bar (R8 app-nav lane):
/// the segmented control's ~480pt intrinsic width overflowed the
/// 240pt column at small window sizes (~30px left of the window edge).
/// A `DietDividerV` seam separates rail from browser.
public struct SidebarColumn: View {
    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var teams: TeamsViewModel
    @ObservedObject private var reminders: RemindersViewModel
    @ObservedObject private var planner: PlannerViewModel
    @ObservedObject private var recordings: RecordingsViewModel
    @ObservedObject private var transcripts: TranscriptsViewModel
    @ObservedObject private var shifts: ShiftsStore
    @ObservedObject private var presence: PresenceStore
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var mentions: MentionStore
    @ObservedObject private var rules: RulesStore
    @ObservedObject private var snooze: SnoozeStore
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
    /// Pop-out tap passthrough (e1-popout): sidebar → host openWindow.
    private let onPopOut: ((String) -> Void)?
    @State private var section: SidebarSection
    /// Reduce Motion (om-a1-motion): section flips cut, never crossfade.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        chats: ChatListViewModel, teams: TeamsViewModel,
        reminders: RemindersViewModel, planner: PlannerViewModel,
        recordings: RecordingsViewModel,
        transcripts: TranscriptsViewModel, shifts: ShiftsStore,
        presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        mentions: MentionStore = MentionStore(),
        rules: RulesStore = RulesStore(),
        snooze: SnoozeStore = SnoozeStore(),
        openChatID: String? = nil,
        initialSection: SidebarSection = .chats,
        initialFilter: String = "",
        channelCreateOpen: Bool = false,
        teamCreateOpen: Bool = false,
        initialFolderID: String? = nil,
        folderManageOpen: Bool = false,
        initialEditingRuleID: String? = nil,
        onOpenChannel: @escaping (String, String) -> Void,
        onPopOut: ((String) -> Void)? = nil
    ) {
        self.chats = chats
        self.teams = teams
        self.reminders = reminders
        self.planner = planner
        self.recordings = recordings
        self.transcripts = transcripts
        self.shifts = shifts
        self.presence = presence
        self.unread = unread
        self.mentions = mentions
        self.rules = rules
        self.snooze = snooze
        self.openChatID = openChatID
        self.initialFilter = initialFilter
        self.channelCreateOpen = channelCreateOpen
        self.teamCreateOpen = teamCreateOpen
        self.initialFolderID = initialFolderID
        self.folderManageOpen = folderManageOpen
        self.initialEditingRuleID = initialEditingRuleID
        _section = State(initialValue: initialSection)
        self.onOpenChannel = onOpenChannel
        self.onPopOut = onPopOut
    }

    public var body: some View {
        HStack(spacing: 0) {
            AppNavRail(selection: $section)
            DietDividerV()
            switch section {
            case .chats:
                ChatListSidebar(model: chats, presence: presence, unread: unread, mentions: mentions, rules: rules, snooze: snooze, initialFilter: initialFilter, initialFolderID: initialFolderID, folderManageOpen: folderManageOpen, initialEditingRuleID: initialEditingRuleID, onPopOut: onPopOut)
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
            case .transcripts:
                TranscriptsBrowser(model: transcripts)
                    .transition(.opacity)
            case .shifts:
                ShiftsBrowser(model: shifts)
                    .transition(.opacity)
            }
        }
        // System-default crossfade when the rail flips sections
        // (instant cut under Reduce Motion). Standard SwiftUI only
        // (no custom drivers).
        .animation(DietMotion.gated(reduceMotion: reduceMotion), value: section)
    }
}

public enum SidebarSection: String, CaseIterable {
    case chats = "Chats"
    case teams = "Teams"
    case reminders = "Reminders"
    case planner = "Planner"
    case recordings = "Recordings"
    case transcripts = "Transcripts"
    case shifts = "Shifts"
}
