// SidebarColumn.swift — sidebar column: app rail + section browsers.
import DietDesign
import OstMacCore
import SwiftUI

/// Sidebar column hosting the chats list, the teams/channels browser,
/// the contacts browser, the reminders browser, the planner boards
/// browser, the recordings browser, the transcripts browser, and the
/// shifts week grid behind the Teams-like `AppNavRail` (fixed 72pt,
/// native buttons).
/// Channel taps open as conversations via
/// `onOpenChannel` (channel id + "Team > #channel" display name).
///
/// The rail replaces the old 7-tab segmented bar (R8 app-nav lane):
/// the segmented control's ~480pt intrinsic width overflowed the
/// 240pt column at small window sizes (~30px left of the window edge).
/// A `DietDividerV` seam separates rail from browser.
///
/// Selection is host-owned (R10 shifts-fullwidth): the host binds
/// `section` so it can swap the whole content area when a full-window
/// module (`.shifts`) is selected. The `.shifts` case below only
/// renders when this column is hosted standalone.
public struct SidebarColumn: View {
    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var teams: TeamsViewModel
    @ObservedObject private var reminders: RemindersViewModel
    @ObservedObject private var planner: PlannerViewModel
    @ObservedObject private var recordings: RecordingsViewModel
    @ObservedObject private var transcripts: TranscriptsViewModel
    @ObservedObject private var shifts: ShiftsStore
    @ObservedObject private var contacts: ContactsStore
    @ObservedObject private var presence: PresenceStore
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var mentions: MentionStore
    @ObservedObject private var rules: RulesStore
    @ObservedObject private var snooze: SnoozeStore
    @ObservedObject private var activity: ActivityStore
    /// In-window pane selection (e1-inwindow): AppState-owned, passed
    /// to the chats sidebar (the rows drive it; the main pane shows).
    private var activityPane: Binding<ActivityPane?>
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
    /// Contacts row tap (f2-contacts): the host's shared person11 open.
    private let onPickContact: ((TeamMember) -> Void)?
    /// Pop-out tap passthrough (e1-popout): sidebar → host openWindow.
    private let onPopOut: ((String) -> Void)?
    @Binding private var section: SidebarSection
    /// Reduce Motion (om-a1-motion): section flips cut, never crossfade.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        chats: ChatListViewModel, teams: TeamsViewModel,
        reminders: RemindersViewModel, planner: PlannerViewModel,
        recordings: RecordingsViewModel,
        transcripts: TranscriptsViewModel, shifts: ShiftsStore,
        contacts: ContactsStore = ContactsStore(),
        presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        mentions: MentionStore = MentionStore(),
        rules: RulesStore = RulesStore(),
        snooze: SnoozeStore = SnoozeStore(),
        activity: ActivityStore = ActivityStore(),
        activityPane: Binding<ActivityPane?> = .constant(nil),
        openChatID: String? = nil,
        section: Binding<SidebarSection>,
        initialFilter: String = "",
        channelCreateOpen: Bool = false,
        teamCreateOpen: Bool = false,
        initialFolderID: String? = nil,
        folderManageOpen: Bool = false,
        initialEditingRuleID: String? = nil,
        onOpenChannel: @escaping (String, String) -> Void,
        onPickContact: ((TeamMember) -> Void)? = nil,
        onPopOut: ((String) -> Void)? = nil
    ) {
        self.chats = chats
        self.teams = teams
        self.reminders = reminders
        self.planner = planner
        self.recordings = recordings
        self.transcripts = transcripts
        self.shifts = shifts
        self.contacts = contacts
        self.presence = presence
        self.unread = unread
        self.mentions = mentions
        self.rules = rules
        self.snooze = snooze
        self.activity = activity
        self.activityPane = activityPane
        self.openChatID = openChatID
        self.initialFilter = initialFilter
        self.channelCreateOpen = channelCreateOpen
        self.teamCreateOpen = teamCreateOpen
        self.initialFolderID = initialFolderID
        self.folderManageOpen = folderManageOpen
        self.initialEditingRuleID = initialEditingRuleID
        _section = section
        self.onOpenChannel = onOpenChannel
        self.onPickContact = onPickContact
        self.onPopOut = onPopOut
    }

    public var body: some View {
        HStack(spacing: 0) {
            AppNavRail(selection: $section)
            DietDividerV()
            switch section {
            case .chats:
                ChatListSidebar(model: chats, presence: presence, unread: unread, mentions: mentions, rules: rules, snooze: snooze, activity: activity, activityPane: activityPane, initialFilter: initialFilter, initialFolderID: initialFolderID, folderManageOpen: folderManageOpen, initialEditingRuleID: initialEditingRuleID, onPopOut: onPopOut)
                    .transition(.opacity)
            case .teams:
                TeamsBrowser(
                    model: teams, openChatID: openChatID, unread: unread,
                    initialFilter: initialFilter,
                    channelCreateOpen: channelCreateOpen,
                    teamCreateOpen: teamCreateOpen,
                    onOpen: onOpenChannel,
                    onPopOut: onPopOut)
                    .transition(.opacity)
            case .contacts:
                ContactsBrowser(model: contacts, presence: presence) { person in
                    onPickContact?(person)
                }
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
    case contacts = "Contacts"
    case reminders = "Reminders"
    case planner = "Planner"
    case recordings = "Recordings"
    case transcripts = "Transcripts"
    case shifts = "Shifts"
}

public extension SidebarSection {
    /// Full-window modules (R10 shifts-fullwidth): when selected, the
    /// module takes the whole window outside the app rail and the chat
    /// viewport hides. Back-nav to any other section restores the
    /// split view (the host keeps `openChatID`, so the conversation
    /// reappears as-is with no reload).
    var takesFullWindow: Bool { self == .shifts }

    /// Shot-hook section from launch args: --show-shifts lands on the
    /// full-width shifts view; --show-contacts lands on the contacts
    /// browser; --show-recordings/--show-planner win over
    /// --show-reminders wins over --show-teams; the create-sheet
    /// hooks land on teams (the sheets hang there).
    static func initialSection(args: [String]) -> SidebarSection {
        if args.contains("--show-shifts") { return .shifts }
        if args.contains("--show-contacts") { return .contacts }
        if args.contains("--show-recordings") { return .recordings }
        if args.contains("--show-recordings-playing") { return .recordings }
        if args.contains("--show-transcripts") { return .transcripts }
        if args.contains("--show-transcripts-showing") { return .transcripts }
        if args.contains("--show-transcripts-actions") { return .transcripts }
        if args.contains("--show-planner") { return .planner }
        if args.contains("--show-reminders") { return .reminders }
        if args.contains("--show-teams") { return .teams }
        if args.contains("--show-channel-create") { return .teams }
        if args.contains("--show-team-create") { return .teams }
        if args.contains("--show-channel-popout") { return .teams }
        return .chats
    }
}
