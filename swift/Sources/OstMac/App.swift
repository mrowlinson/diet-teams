// Better Teams — THE app (om-auth-gate): the main window is gated on the
// AuthViewModel 13-state gate — unsigned shows the full sign-in UI
// (device code, copy/open-browser, polling, expiry/refresh, sign-out)
// where the chats would be; chats, conversation, and the live feed
// stay parked until signedIn. Settings embeds the same shared model.
// --demo bypasses the gate fully offline.
//
// Usage:
//   Better Teams [--demo | --demo-rich | --demo-reactions | --demo-botposts] [--chat <id> [--name <n>]] [--say <text>]
//          [--show-about] [--show-settings] [--auth-state <name>]
//          [--show-call incoming|active|live] [--show-av]
// --show-call seeds the call banner offline (demo state, no core calls).
// --demo runs fully offline (canned chats/messages, local send echo).
// --demo-rich is --demo preselected on the rich thread (mentions, code,
// edited + failed bubbles, Yesterday/Today separators).
// --demo-reactions is --demo preselected on the reacted thread
// (counts on bubbles, picker via right-click — shot hook).
// --demo-botposts is --demo preselected on the bot-posts thread
// (RSS digest rows, card row, unparseable placeholder — shot hook).
// --demo-showcase is --demo preselected on the showcase thread (every
// rich feature in one conversation + two seeded pins — shot hook).
// --show-code is --demo-rich plus two seeded fenced-code bubbles at the
// tail (received python + sent swift — top10-code shot hook).
// --chat preselects (or opens directly when absent from the list).
// --say auto-sends once into the open chat. In live mode that is a REAL
// send via core — never use it on shared chats for testing.
// --show-about / --show-settings / --show-av open those windows at launch (shot hooks).
// --show-av-share scrolls the A/V window to the Screen share tile (top10-share shot hook).
// --show-settings-keywords opens the sanitized fixed Settings view
// scrolled to the Keyword alerts section (R6 shot hook, offline).
// --show-settings-calls opens it preselected on Calls (test-call
// section shot hook, offline). --show-settings-summaries preselects
// Summaries (provider picker shot hook, offline).
// --show-settings-attention preselects Notifications on the Attention
// surface with seeded windows + schedules (e2-attention shot hook,
// offline; combine with --show-diagnostics for the rows).
// --show-settings-templates opens the real Templates section
// standalone in a compact window (e2-canned shot hook, offline).
// --show-settings-chats preselects Chats (Templates section
// in-situ shot hook, offline).
// --show-settings-composer preselects Chats with the full detail
// (through the Quick Composer section) fitting the frame
// (f1-composer shot hook, offline).
// --show-catchup-ondevice is --show-catchup with the on-device provider (canned, shot hook).
// --show-meeting seeds the Meeting window offline + opens it (shot hook).
// --show-diagnostics opens the Diagnostics window at launch (shot hook).
// --show-calls opens the Recent Calls window at launch (shot hook).
// --show-meetings opens the Meetings window at launch (shot hook).
// --av-mic-denied seeds the Call A/V panel's mic-denied hint (shot hook).
// --show-teams opens the sidebar on the Teams browser (shot hook).
// --show-channel-create / --show-team-create open the sidebar on
// Teams with that create sheet open (shot hooks, demo offline).
// --show-shared opens the conversation on the Shared files tab (shot hook).
// --show-reminders opens the sidebar on the Reminders browser (shot hook).
// --show-planner opens the sidebar on the Planner browser (shot hook).
// --show-recordings opens the sidebar on the Recordings browser (shot hook).
// --show-recordings-playing also auto-plays the first row (shot hook).
// --show-transcripts opens the sidebar on the Transcripts browser (shot hook).
// --show-transcripts-showing also loads the first row's turns (shot hook).
// --show-transcripts-actions is --show-transcripts-showing plus canned
// on-device action items extracted over the turns (f1-actions shot hook).
// --show-shifts opens the sidebar on the full-width Shifts module (shot hook).
// --show-action-items stretches the demo thread past 20 messages and
// auto-opens the action-items popover with canned bullets (f1-actions
// shot hook, offline).
// --show-action-items-window renders the same popover content
// standalone in the main window (f1-actions shot hook, offline):
// NSPopover auto-open is environment-flaky (blank orphans; pre-existing
// hooks fail the same way), so pixel proof goes through this path.
// --show-notes opens the conversation on the Notes tab (shot hook).
// --show-jump opens the Cmd+K jump palette at launch (shot hook).
// --show-quickcompose summons the floating quick-composer panel at
// launch (f1-composer shot hook, offline with --demo);
// --quickcompose-query <q> / --quickcompose-text <t> preseed its
// fields and --quickcompose-pick-first pre-picks the top match.
// --show-forward opens the forward sheet (jump palette re-targeted at a
// demo bubble) at launch (om-msgactions shot hook, offline).
// --jump-query <q> / --filter-query <q> preseed the palette/sidebar
// filters (shot hooks).
// --show-gif opens the GIF picker popover at launch (shot hook).
// --show-picker opens the reaction more-picker popover on the
// bottom-most reacted bubble at launch (om-react-polish shot hook,
// offline).
// --show-catchup stretches the demo thread past 20 messages and
// auto-opens the catch-up sheet with a canned summary (shot hook,
// offline, throwaway defaults — never the real ones).
// --show-reply opens the demo replies thread with the compose-reply
// chip armed on Tom's question (shot hook, offline).
// --show-sidebarchurn swaps the demo list for the churn dataset
// (meeting + bot + system rows) and folds a beacon burst after load,
// so the sidebar shows the stable result (shot hook, offline).
// --show-folders seeds throwaway Work/Family folders + auto-rules and
// preselects the Work folder (d1-folders shot hook, offline).
// --show-folders-manage is --show-folders with the manager sheet open
// (d1-folders rules-editor shot hook, offline).
// --show-history preselects the 3-day history thread (with --demo;
// shot hook, offline). --show-history-error opens it empty with a
// canned fetch failure + Try Again (shot hook, offline).
// --scroll-to <message-id> lands the initial scroll on that bubble
// (scroll-state shots; consumed by ConversationView).
// --show-edit / --show-delete open the edit sheet / delete confirm for
// the first own bubble at launch (om-editdel shot hooks, demo offline).
// --show-schedule opens the schedule-send popover at launch and
// --show-scheduled opens the pending queue sheet (d2-send shot hooks,
// demo offline; seed ~/.config/Better\ Teams/scheduled.json for queue rows).
// --show-notif-live injects one canned trouter event through the real
// live path (rules → banner) and logs the decision + delivered
// readback (om-notif-live proof hook, demo offline; ignored live).
// --show-popout pops a second chat beside the main selection at launch
// (e1-popout shot hook, offline with --demo); --popout-chat <id> picks
// which chat (else the first row that is not the main selection).
// --teams-frame-url <url> opens the App Frame on that Teams deep link
// (default https://teams.microsoft.com); --show-teams-frame opens it at
// the default URL; --teams-frame-full skips the rail/header crop;
// --teams-frame-calibrate overlays draggable crop guides. DISPLAY ONLY —
// owner completes login live (see proof doc).
// --auth-state <name> opens the Auth window with a canned state, never
// touching core/network (names: signed-out, starting, code, polling,
// browser, browser-working, signed-in, expired, refreshing,
// refresh-failed, error). `--state` is an alias. Without it the Auth
// window shows the live session.
//
// Realtime routing: the Trouter socket is global (one feed for all
// chats), so switching chats does NOT restart the socket — the list
// ingests every event (preview refresh + reorder), while bubbles are
// filtered to the open chat (`isFor(chatID:)`). A resync gap
// re-fetches the open chat plus the list.
import AppKit
import Combine
import DietDesign
import Foundation
import OstMacChatList
import OstMacCore
import SwiftUI
import UserNotifications

@main
struct OstMacAppMain: App {
    @StateObject private var state: AppState
    private let cannedAuth: AuthViewModel?

    init() {
        ColdStart.arm() // top10-menubar: launch-timeline t0 (first line)
        let args = CommandLine.arguments
        _state = StateObject(wrappedValue: AppState(args: args))
        if let name = Self.authStateName(args: args) {
            cannedAuth = .demo(Self.authState(named: name))
        } else {
            cannedAuth = nil
        }
    }

    /// --jump-query value (shot hook: preseed the palette filter).
    static func jumpQuery(args: [String]) -> String {
        if let i = args.firstIndex(of: "--jump-query"), i + 1 < args.count {
            return args[i + 1]
        }
        return ""
    }

    /// --filter-query value (shot hook: preseed the sidebar filter).
    static func filterQuery(args: [String]) -> String {
        if let i = args.firstIndex(of: "--filter-query"), i + 1 < args.count {
            return args[i + 1]
        }
        return ""
    }

    /// --<flag> value (quick-composer shot preseeds); "" when absent.
    static func argValue(args: [String], flag: String) -> String {
        if let i = args.firstIndex(of: flag), i + 1 < args.count {
            return args[i + 1]
        }
        return ""
    }

    /// --auth-state value (--state alias); nil = live auth.
    static func authStateName(args: [String]) -> String? {
        for flag in ["--auth-state", "--state"] {
            if let i = args.firstIndex(of: flag), i + 1 < args.count {
                return args[i + 1]
            }
        }
        return nil
    }

    static func authState(named: String) -> AuthState {
        switch named {
        case "signed-out": .signedOut
        case "starting": .starting
        case "code": .code(.demo)
        case "polling": .polling(.demo, attempts: 2)
        case "browser": .browser(.demo)
        case "browser-working": .browserWorking(.demo)
        case "signed-in": .signedIn
        case "expired": .expired
        case "refreshing": .refreshing
        case "refresh-failed": .refreshFailed("refresh: token request failed (demo)")
        case "error": .error("device_start: network unreachable (demo)")
        default: .signedOut
        }
    }

    var body: some Scene {
        WindowGroup("Better Teams") {
            RootView()
                .environmentObject(state)
        }
        .defaultSize(width: 1000, height: 640)
        Window("About Better Teams", id: AppIdentity.aboutWindowID) {
            AboutView()
        }
        .defaultSize(width: 360, height: 340)
        .windowResizability(.contentSize)
        Window("Better Teams Auth", id: AppIdentity.authWindowID) {
            if let cannedAuth {
                AuthView(model: cannedAuth)
                    .background(DietColor.windowColor)
            } else {
                AuthView(model: state.auth)
                    .background(DietColor.windowColor)
                    .task { await state.auth.refreshStatus() }
            }
        }
        .defaultSize(width: 440, height: 520)
        Window("Call A/V", id: AppIdentity.avWindowID) {
            // top10-menubar: LazyView — capture models + camera
            // enumeration build on first open, never at launch.
            LazyView { AvPanelView(screenShare: state.screenShare) }
        }
        .defaultSize(width: 600, height: 740)
        Window("Call", id: AppIdentity.callWindowID) {
            // top10-menubar: LazyView — capture models build on
            // first open (first call join), never at launch.
            LazyView { InCallView(call: state.call) }
        }
        .defaultSize(width: 420, height: 560)
        Window("Recent Calls", id: AppIdentity.callsWindowID) {
            CallHistoryView(store: state.history)
        }
        .defaultSize(width: 380, height: 480)
        Window("Diagnostics", id: AppIdentity.diagWindowID) {
            DiagnosticsView()
                .environmentObject(state)
        }
        .defaultSize(width: 440, height: 480)
        Window("Meetings", id: AppIdentity.meetWindowID) {
            CalendarWeekBrowser(week: state.calWeek, meetings: state.meetings)
                .frame(minWidth: 380, minHeight: 480)
                .task {
                    await state.calWeek.load()
                    state.meetings.refresh()
                }
        }
        .defaultSize(width: 420, height: 560)
        Window("Meeting", id: AppIdentity.meetingWindowID) {
            MeetingPanel(roster: state.meeting, chat: state.meetingChat)
        }
        .defaultSize(width: 720, height: 480)
        // teams-frame FULL: registry + switcher + yanked escapes + SSO
        // popups + downloads. --teams-frame-url <deep-link> opens it
        // (default teams.microsoft.com); --show-teams-frame opens it at
        // the default URL; --teams-frame-full bypasses the rail/header
        // crop; --teams-frame-calibrate overlays draggable crop guides.
        // DISPLAY ONLY — see TeamsFrame.swift.
        Window("App Frame", id: AppIdentity.teamsFrameWindowID) {
            TeamsFrameWindow(
                store: state.teamsFrame,
                launchURL: TeamsFrameConfig.launchURL(args: CommandLine.arguments),
                fullFrame: TeamsFrameConfig.fullFrame(args: CommandLine.arguments),
                calibrate: TeamsFrameConfig.calibrate(args: CommandLine.arguments))
        }
        .defaultSize(width: 1100, height: 750)
        // e1-popout: one value-driven window per popped chat (re-pop of
        // the same id focuses the existing window — no dups). WindowGroup
        // carries the value API (plain Window has no `for:` overload).
        WindowGroup(Text("Chat"), id: AppIdentity.chatPopoutID, for: String.self) { value in
            if let chatID = value.wrappedValue {
                PopOutRootView(state: state, chatID: chatID)
            } else {
                // Stale restored window (value lost): close itself.
                PopOutEmptyView()
            }
        }
        .defaultSize(width: 560, height: 640)
        // gap-g2: one value-driven window per open account (re-open of
        // the same id focuses the existing window — no dups).
        WindowGroup(
            Text("Account"), id: AppIdentity.accountWindowID,
            for: String.self
        ) { value in
            if let accountID = value.wrappedValue {
                AccountWindowRootView(state: state, accountID: accountID)
            } else {
                // Stale restored window (value lost): close itself.
                PopOutEmptyView()
            }
        }
        .defaultSize(width: 900, height: 620)
        // top10-menubar: menu-bar extra (presence dot + unread count;
        // popover = quick-chat triage). The chats VM is passed by
        // source (AppState rebuilds it on account switch).
        MenuBarExtra {
            MenuBarPopoverView(
                chatsSource: { [state] in state.chats },
                unread: state.unread,
                presence: state.presence,
                onOpenChat: { id in
                    NotificationCenter.default.post(
                        name: .omNotifOpenChat, object: nil,
                        userInfo: ["chatID": id])
                    NSApp.activate(ignoringOtherApps: true)
                },
                onOpenMain: { NSApp.activate(ignoringOtherApps: true) },
                onQuit: { NSApp.terminate(nil) })
        } label: {
            MenuBarLabelView(unread: state.unread, presence: state.presence)
        }
        .menuBarExtraStyle(.window)
        Settings {
            if CommandLine.arguments.contains("--show-settings-templates") {
                // Shot hook (e2-canned): the real Templates section
                // standalone in a compact window.
                TemplatesShotView(canned: state.canned)
            } else if SettingsRouting.useIsolatedDemo(
                isDemo: state.isDemo, args: CommandLine.arguments)
            {
                // Isolated fixed view (om-settings-org): demo launches
                // and the keywords/attention shots never embed the LIVE
                // auth model (demo isolation); rules load from the
                // seeded rules.json like the live store.
                SettingsView(account: SettingsRouting.isolatedDemoAccount)
            } else {
                SettingsView(
                    auth: state.auth, catchUp: state.catchUp, notifs: state.notifs,
                    rules: state.rules, chats: state.chats,
                    quiet: state.quietHours, focus: state.focusSync,
                    sched: state.presenceSchedule, truth: state.presenceTruth,
                    blocked: state.blocked,
                    accounts: state.accounts, call: state.call,
                    canned: state.canned, ghost: state.ghost,
                    density: state.density,
                    loginItems: state.loginItems,
                    onAccountAdded: { state.completePendingAdd($0) },
                    onRemoveAccount: { state.removeAccount($0) })
            }
        }
        .commands { OstMacCommands() }
    }
}

/// App menu: About opens our About window (standard panel replaced);
/// Settings… (from the Settings scene) and Quit stay automatic.
/// Sign In… opens the Auth window (same shared gate model).
private struct OstMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Better Teams") { openWindow(id: AppIdentity.aboutWindowID) }
        }
        CommandGroup(after: .appInfo) {
            Button("Sign In…") { openWindow(id: AppIdentity.authWindowID) }
                .keyboardShortcut("I", modifiers: [.command, .shift])
            Divider() // native menu separator; keep.
        }
        CommandMenu("Call") {
            Button("In-Call Window") { openWindow(id: AppIdentity.callWindowID) }
            Button("Join Meeting…") { openWindow(id: AppIdentity.meetWindowID) }
                .keyboardShortcut("j", modifiers: .command)
            Button("Call A/V Test") { openWindow(id: AppIdentity.avWindowID) }
            Button("Recent Calls") { openWindow(id: AppIdentity.callsWindowID) }
            Button("Meeting Chat…") { openWindow(id: AppIdentity.meetingWindowID) }
        }
        CommandMenu("Go") {
            Button("Jump to Chat…") {
                NotificationCenter.default.post(name: .showJumpPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            // e2-saved entry: a sheet, NOT an 8th sidebar tab (R8
            // app-nav-sidebar owns the nav surface concurrently — see X1).
            Button("Saved Messages…") {
                NotificationCenter.default.post(name: .showSavedMessages, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            // f1-composer: in-app entry (the global hotkey is the main
            // one; this mirrors its default combo for discoverability).
            Button("New Quick Message…") {
                NotificationCenter.default.post(name: .showQuickComposer, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .control])
        }
        CommandGroup(after: .windowList) {
            Button("Diagnostics") { openWindow(id: AppIdentity.diagWindowID) }
        }
        // teams-frame FULL: instant destroy of the app frame.
        CommandMenu("View") {
            Button("Kill App Frame") {
                NotificationCenter.default.post(name: .killTeamsFrame, object: nil)
            }
        }
    }
}

/// f1-composer: one off-screen quick send (the open-target path goes
/// through ConversationStore instead, so its bubble/errors surface
/// there). Demo records locally; live failures land here (no toast —
/// the target timeline isn't open to own one).
struct QuickSendRecord: Equatable {
    let targetID: String
    let targetName: String
    let text: String
    let failed: Bool
    let error: String?
}

@MainActor
final class AppState: ObservableObject {
    let isDemo: Bool
    /// Blocked users (om-leave-block): shared by the chat list (row
    /// filter), Settings (Unblock), Diagnostics (count), and the live
    /// feed gate below. Demo runs memory-only (never the real defaults).
    /// Rebuilt per account on switch (d1-accounts).
    @Published var blocked: BlockedStore
    /// Rebuilt per account on switch (d1-accounts; pins/folders/blocked
    /// are per-account namespaces).
    @Published var chats: ChatListViewModel
    let teams: TeamsViewModel
    let reminders: RemindersViewModel
    let planner: PlannerViewModel
    let recordings: RecordingsViewModel
    let transcripts: TranscriptsViewModel
    let meetings: MeetingsViewModel
    /// Calendar week grid backing the Meetings window (B1 merge).
    let calWeek: CalendarWeekStore
    /// Shifts week grid backing the sidebar Shifts tab (B1 merge).
    let shifts: ShiftsStore
    /// Contacts directory + speed dial (om-f2-contacts): the sidebar
    /// Contacts section searches through this store. Demo runs the
    /// offline people index; live hits Graph via core.
    let contacts: ContactsStore
    let conv = ConversationStore()
    /// Pop-out registry (e1-popout): visible chat ids + per-chat stores +
    /// draft cache, bound to the main store for send mirroring.
    let popouts = PopOutStore()
    /// Message search (om-ja-search): the jump palette's Messages scope
    /// searches through this store. Demo runs substring-over-fixtures
    /// (offline); live hits Graph via core.
    let messageSearch: MessageSearchStore
    /// Offline message index (gap-g6g7): attached to `messageSearch`
    /// for offline-first merge. Fed by history fetches (`conv`
    /// onHistory) + realtime ingest; persists per-account OMIX.
    let localSearch = LocalSearchStore()
    /// Sticky palette search memory (gap-g6g7): scope chip + last
    /// query + 5 recents. Device-scoped (global, like picker flags).
    let searchRecents = SearchRecentsStore()
    /// Indexed doc count (Diagnostics; updated on every index write).
    @Published var searchIndexDocs = 0
    /// Last index load/save failure (Diagnostics; nil when clear).
    @Published var searchIndexError: String?
    /// Account whose file backs `localSearch` right now.
    private var searchIndexAccountID = AccountProfile.defaultID
    /// Debounced OMIX save (2s quiet window after each index write).
    private var searchIndexSaveTask: Task<Void, Never>?
    /// File + people search (om-jb-filesearch): the jump palette's
    /// Files/People sections search through this store. Demo runs
    /// substring-over-fixtures (offline); live hits Graph via core.
    let filePeople: FilePeopleSearchStore
    let shared = SharedFilesStore()
    let feed = RealtimeFeed()
    /// gap-g1 2nd feed: REST sweep over inactive accounts (the live
    /// trouter serves the active profile only). Started with the feed in
    /// live mode; the App timer drives it (30s, ungated — it must fire
    /// while minimized, unlike the 2s visible-only tick).
    let bgPoller = BackgroundAccountPoller()
    /// gap-g1 unified roll-up: background .notify counts per inactive
    /// account, drained into the live UnreadStore on switch.
    private var bgRollup = BackgroundUnreadRollup()
    let typing = TypingStore()
    let notifs = MessageNotifications()
    /// e2-attention: system Focus sync (quiet source) + presence
    /// schedules (timetable-driven own status). The schedule adopts
    /// set-echoes into `presence` (weak) and pauses on manual picker
    /// sets via `presence.manualSetHook`. Init-assigned (shot hook may
    /// point them at the throwaway suite).
    let quietHours: QuietHoursStore
    let focusSync: FocusSyncStore
    let presenceSchedule: PresenceScheduleStore
    /// top10-presence: status lock + activity truth + change log +
    /// devices. Init-assigned next to the schedule (shot hook may point
    /// it at the throwaway suite).
    let presenceTruth: PresenceTruthStore
    /// d2-send: per-chat snooze expiries + the scheduled-send queue.
    let snooze = SnoozeStore()
    let scheduled = ScheduledSendStore()
    /// e2-canned: user-authored message templates (composer + Settings).
    let canned = CannedResponsesStore()
    // om-mention-alerts: the Mentions row count owns the Dock tile, so
    // unread counts stay sidebar-only here (per-chat badges + Diagnostics).
    let unread = UnreadStore(dock: NullDockBadge())
    let mentions = MentionStore()
    /// e1-activity: notification history + mentions-center data.
    let activity = ActivityStore()
    /// In-window pane (e1-inwindow): sidebar Activity / All Mentions
    /// selection; the detail shows the list while set. Cleared by
    /// every chat open (the `open` funnel) and every pane jump.
    @Published var activityPane: ActivityPane?
    /// Rail selection (R10 shifts-fullwidth): host-owned so RootView
    /// can swap the whole content area for full-window modules
    /// (`.shifts` — see `SidebarSection.takesFullWindow`).
    @Published var sidebarSection: SidebarSection
    let receipts = ReceiptStore()
    /// Rebuilt per account on switch (d1-accounts).
    @Published var pinnedMessages: PinnedMessageStore
    /// Cross-chat saved collection (e2-saved). Rebuilt per account on
    /// switch (d1-accounts) like pins.
    @Published var savedMessages: SavedMessageStore
    let auth = AuthViewModel()
    let presence = PresenceStore()
    /// Ghost mode (f1-ghost): suppresses own read-receipt PUTs and
    /// presence writes while on (injected into receipts/presence/
    /// presenceSchedule below; toggles persist, counters clear out).
    let ghost = GhostStore()
    /// teams-frame FULL lifecycle (registry + pool + keep-alive + kill).
    let teamsFrame = TeamsFrameStore()
    /// Message density (f2-density): Comfortable/Compact spacing.
    /// Published into the environment via DensityHost (RootView +
    /// pop-outs) and bound in Settings → Chats → Appearance.
    let density = DensityStore()
    let call: CallStore
    /// Rebuilt per account on switch (d1-accounts).
    @Published var history = CallHistoryStore()
    let meeting = MeetingRosterStore()
    /// Rebuilt per account on switch (d1-accounts).
    @Published var meetingChat = MeetingChatStore()
    /// Multi-account list + per-account VMs (d1-accounts). The `auth`
    /// VM above is the live gate object, repointed at the active
    /// profile on every switch (stable identity for all observers).
    /// Init-assigned (gap-g2): its profile flips serialize through
    /// `profileGate` below.
    let accounts: AccountStore
    /// gap-g2: serializes every core-profile flip (switches, restore)
    /// against account-window flip-flop ops; records the active
    /// profile so flip-backs land on the CURRENT active.
    let profileGate = AccountProfileGate()
    /// gap-g2: side-by-side account windows (visible set + cached
    /// per-account graphs).
    let accountWindows = AccountWindowRegistry()
    /// gap-g2: armed account-window request (RootView opens the window
    /// for it, then clears it — openWindow lives in the view layer only).
    @Published var pendingAccountWindowID: String?
    /// gap-g2: last flip-flop gap-close (coalesces resyncs across
    /// rapid window ops — trailing gaps still close, ≤2s stale).
    private var lastWindowResync = Date.distantPast
    /// True between an account switch/add and its quiet reload landing
    /// (keeps the gate open across the `.unknown` repoint beat).
    @Published var switchingAccount = false
    /// Screen-share owner, created on first A/V use (top10-menubar:
    /// no media objects at launch — the ScreenShareModel init notes
    /// into ColdStart, so the launch log proves zero).
    lazy var screenShare = ScreenShareModel()
    /// Opt-in login item (top10-menubar: default off; Settings toggle).
    let loginItems = LoginItemStore()
    let notes = NotesStore()
    let showNotes: Bool
    let catchUp: CatchUpStore
    /// --show-catchup: long demo thread + canned summary, sheet auto-opens.
    let showCatchUp: Bool
    /// On-device action-items extraction (f1-actions): live by
    /// default, canned under --show-action-items / --show-transcripts-actions.
    let actionItems: ActionItemsStore
    /// --show-action-items: long demo thread + canned bullets, popover auto-opens.
    let showActionItems: Bool
    /// --show-forward: forward sheet opens for a demo bubble at launch.
    let showForward: Bool
    /// Bubble being forwarded (om-msgactions): set sheets the palette.
    @Published var forwardMessage: ChatMessage?
    /// --show-reply: demo replies thread + armed compose-reply chip.
    let showReply: Bool
    /// --show-popout: pop a second chat beside the main selection
    /// (e1-popout shot hook, offline with --demo).
    let showPopout: Bool
    /// Armed pop-out request (RootView opens the window for it, then
    /// clears it — openWindow lives in the view layer only).
    @Published var pendingPopoutID: String?
    /// --show-sidebarchurn: churn dataset + post-load beacon burst.
    let showSidebarChurn: Bool
    /// --show-history-error: demo history thread, empty + canned fetch error.
    let showHistoryError: Bool
    /// History shot launch (--show-history*): memory key store, so the
    /// shot never touches the real keychain (no SecurityAgent prompt).
    let showHistory: Bool
    /// --show-notif-live: offline banner-proof injection (demo only).
    let showNotifLive: Bool
    /// --show-pins: demo 1:1 thread + two seeded pins (strip shot).
    let showPins: Bool
    /// --demo-showcase: showcase thread + two seeded pins (hero shot).
    let showShowcase: Bool
    /// --show-folders: preselected Work folder id (shot hook; nil for
    /// every other launch — the sidebar opens on All chats).
    let folderShotSelection: String?
    /// --show-folders-manage: first seeded rule id, expanded in the
    /// manager sheet (shot hook; nil otherwise).
    let folderShotEditingRuleID: String?
    @Published var openChatID: String?
    @Published var signedIn: Bool?
    @Published var coreVersion = "?"
    @Published var initCode: Int32 = -99
    @Published var feedState: RealtimeFeed.State = .stopped
    @Published var feedEvents = 0
    @Published var feedResyncs = 0
    @Published var feedPolls = 0
    @Published var feedTyping = 0
    @Published var feedRoster = 0
    @Published var feedError: String?
    // om-mention-alerts: breakthrough/suppression counters (Diagnostics only).
    @Published var mentionBreakthroughs = 0
    @Published var mentionDNDSuppressions = 0
    @Published var mentionQuietSuppressions = 0
    /// Rules notify/skip decisions this session + last reason
    /// (om-notif-live; Diagnostics window only).
    @Published var notifPosted = 0
    @Published var notifSkipped = 0
    @Published var notifLastReason = ""
    /// gap-g1 background arrivals handled this session (inactive
    /// accounts; their banners count in notifPosted above).
    @Published var bgEvents = 0
    @Published var showJump = false
    /// Saved collection sheet (e2-saved): Go-menu command + --show-saved.
    @Published var showSaved = false
    /// f1-composer: global hotkey manager (Carbon seam) + floating
    /// panel controller. AppKit-level (no SwiftUI scene) so summon
    /// works backgrounded and with all windows closed.
    let quickComposeHotKey = QuickComposerHotKey()
    private var composerPanel: QuickComposerPanelController?
    /// --show-quickcompose: summon the composer at launch (shot hook).
    let showQuickComposerShot: Bool
    /// One-shot field preseeds (--quickcompose-query/-text/-pick-first);
    /// consumed by the first summon, blank after.
    private var quickComposePreseed: (query: String, text: String, pickFirst: Bool)?
    /// Last off-screen quick send (demo record + live failure surface).
    @Published var lastQuickSend: QuickSendRecord?
    @AppStorage("selectedChatID") private var persistedSelection: String?

    private let preselectID: String?
    private let preselectName: String?
    private let autoSay: String?
    /// --demo-arrive-after value (perf-harness delay hook: secs after
    /// content open to inject a peer arrival through handleRealtime).
    private let arriveAfter: Double?
    /// --demo-arrive-text value (arrival bubble text; default below).
    private let arriveText: String?
    /// --demo-arrive-edit flag (arrival retexts its own bubble +2s).
    private let arriveEdit: Bool
    /// --popout-chat value (e1-popout shot hook: which chat to pop).
    private let popoutShotID: String?
    private var cancellables = Set<AnyCancellable>()
    /// Chat-list wiring (rebuilt with `chats` on account switch).
    private var chatsCancellables = Set<AnyCancellable>()
    private var stateTimer: Timer?
    /// gap-g1 sweep timer (30s, ungated — background accounts must
    /// banner while minimized, when the 2s tick stands down).
    private var bgTimer: Timer?
    private var started = false
    private var contentOpened = false
    // om-rules: notify/skip rules over the live feed (RulesStore loads
    // rules.json once; Settings mute edits apply live, no relaunch).
    // meetingDedup collapses meeting bursts; ownerMRI is learned async
    // (name backup covers the gap).
    private var meetingDedup = MeetingStartDedup()
    let rules = RulesStore()
    private var ownerMRI: String?

    init(args: [String]) {
        // gap-g2: every AccountStore profile flip serializes through
        // the gate (window flip-flop ops queue behind the same lock);
        // the gate seeds from the restored store (the one truth).
        accounts = AccountStore(profileSet: { [profileGate] id in
            try profileGate.setActive(id) { try RustCore.profileSet($0) }
        })
        profileGate.seed(accounts.activeID ?? AccountProfile.defaultID)
        // e2-attention: attention stores (shot hook may point them at
        // the throwaway suite + seed them; seeded values also feed the
        // Diagnostics rows). First: `let`s without defaults must land
        // before any self use.
        if args.contains("--show-settings-attention") {
            let suite = UserDefaults(suiteName: "shot-attention") ?? .standard
            suite.removePersistentDomain(forName: "shot-attention")
            let quiet = QuietHoursStore(defaults: suite)
            quiet.windows = [
                QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60),
                QuietHoursWindow(
                    enabled: true, startMinutes: 12 * 60, endMinutes: 13 * 60,
                    days: [2, 3, 4, 5, 6]),
            ]
            quietHours = quiet
            let focus = FocusSyncStore(defaults: suite, reader: { false })
            focus.syncEnabled = true
            focusSync = focus
            let sched = PresenceScheduleStore(defaults: suite, presence: presence)
            sched.enabled = true
            sched.entries = [
                PresenceScheduleEntry(
                    window: QuietHoursWindow(
                        enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60,
                        days: [2, 3, 4, 5, 6]),
                    status: .busy),
                PresenceScheduleEntry(
                    window: QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60),
                    status: .offline),
            ]
            presenceSchedule = sched
            presenceTruth = PresenceTruthStore(defaults: suite, presence: presence)
        } else {
            quietHours = QuietHoursStore()
            focusSync = FocusSyncStore()
            // Schedule adopts set-echoes into presence (weak).
            presenceSchedule = PresenceScheduleStore(presence: presence)
            presenceTruth = PresenceTruthStore(presence: presence)
        }
        // Ghost (f1-ghost): one store gates all three outbound paths
        // (receipt sends, manual presence sets, scheduled sets).
        receipts.ghost = ghost
        presence.ghost = ghost
        presenceSchedule.ghost = ghost
        // top10-presence: truth auto-sets hold under ghost; the schedule
        // holds while a lock owns the status and reports its fires to
        // the truth log; idle logic yields to active schedule windows.
        presenceTruth.ghost = ghost
        presenceSchedule.externalHold = { [weak truth = presenceTruth] in
            truth?.isLocked() ?? false
        }
        presenceSchedule.onApplied = { [weak truth = presenceTruth] status in
            truth?.noteScheduledSet(status)
        }
        presenceTruth.scheduleActive = { [weak schedule = presenceSchedule] in
            schedule?.activeEntry() != nil
        }
        isDemo = args.contains("--demo") || args.contains("--demo-rich")
            || args.contains("--demo-reactions") || args.contains("--show-sidebarchurn")
            || args.contains("--demo-botposts") || args.contains("--show-pins")
            || args.contains("--demo-showcase")
            || args.contains("--show-folders") || args.contains("--show-folders-manage")
            || args.contains("--show-saved") || args.contains("--show-code")
        showNotes = args.contains("--show-notes")
        showJump = args.contains("--show-jump") // shot hook: palette open at launch
        showQuickComposerShot = args.contains("--show-quickcompose") // shot hook: composer open at launch
        if showQuickComposerShot {
            quickComposePreseed = (
                query: OstMacAppMain.argValue(args: args, flag: "--quickcompose-query"),
                text: OstMacAppMain.argValue(args: args, flag: "--quickcompose-text"),
                pickFirst: args.contains("--quickcompose-pick-first"))
        } else {
            quickComposePreseed = nil
        }
        activityPane = ActivityPane.initial(
            showActivity: args.contains("--show-activity"),
            showMentions: args.contains("--show-mentions"))
        sidebarSection = SidebarSection.initialSection(args: args)
        let showSavedShot = args.contains("--show-saved") // shot hook: saved sheet open at launch
        showSaved = showSavedShot
        if showSavedShot {
            // Shot hook only: throwaway defaults (never the real saves),
            // three seeded saves across a 1:1, a group, and a channel.
            let seeded = SavedMessageStore(
                defaults: UserDefaults(suiteName: "shot-saved") ?? .standard)
            seeded.adopt(Self.savedShotSeeds)
            savedMessages = seeded
        } else {
            savedMessages = SavedMessageStore()
        }
        call = CallStore(demo: isDemo)
        showCatchUp = args.contains("--show-catchup") || args.contains("--show-catchup-ondevice")
        showActionItems = args.contains("--show-action-items")
        if showActionItems || args.contains("--show-transcripts-actions")
            || args.contains("--show-action-items-window")
        {
            // Shot hooks only: canned on-device extraction, no model.
            let stub = args.contains("--show-transcripts-actions")
                ? Self.actionItemsTranscriptStub : Self.actionItemsThreadStub
            actionItems = ActionItemsStore(transport: OnDeviceCatchUpTransport(
                runner: OnDeviceMockRunner(stub: stub),
                availability: { .available }))
        } else {
            actionItems = ActionItemsStore()
        }
        showForward = args.contains("--show-forward")
        showReply = args.contains("--show-reply")
        showSidebarChurn = args.contains("--show-sidebarchurn")
        showHistoryError = args.contains("--show-history-error")
        showHistory = args.contains("--show-history") || showHistoryError
        showNotifLive = args.contains("--show-notif-live")
        showPins = args.contains("--show-pins")
        showShowcase = args.contains("--demo-showcase")
        if showPins || showShowcase {
            // Shot hook only: throwaway defaults (never the real pins).
            pinnedMessages = PinnedMessageStore(
                defaults: UserDefaults(suiteName: "shot-pins") ?? .standard)
        } else {
            pinnedMessages = PinnedMessageStore()
        }
        if showCatchUp {
            // Shot hook only: throwaway defaults (never the real ones),
            // canned summary, no network.
            if args.contains("--show-catchup-ondevice") {
                let runner = OnDeviceMockRunner(stub: Self.catchUpDemoSummary)
                let store = CatchUpStore(
                    onDeviceTransport: OnDeviceCatchUpTransport(
                        runner: runner, availability: { .available }),
                    defaults: UserDefaults(suiteName: "shot-catchup") ?? .standard,
                    keyStore: CatchUpMemoryKeyStore())
                store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
                catchUp = store
            } else {
                let canned = CatchUpCannedTransport(stub: Self.catchUpDemoSummary)
                let store = CatchUpStore(
                    cliTransport: canned,
                    defaults: UserDefaults(suiteName: "shot-catchup") ?? .standard,
                    keyStore: CatchUpMemoryKeyStore())
                store.adopt(CatchUpConfig(enabled: true, apiKey: "demo"))
                catchUp = store
            }
        } else if showHistory {
            // Shot hook only: memory key store, never the real keychain
            // (--show-catchup precedent; no SecurityAgent prompt).
            catchUp = CatchUpStore(keyStore: CatchUpMemoryKeyStore())
        } else if isDemo || args.contains(where: { $0.hasPrefix("--show-") }) {
            // Demo/shot builds: memory key store always, never the
            // real keychain (re-signed demo builds must not prompt).
            catchUp = CatchUpStore(keyStore: CatchUpMemoryKeyStore())
        } else {
            catchUp = CatchUpStore()
        }
        // Shot hook: --show-call incoming|active seeds the banner offline.
        if let i = args.firstIndex(of: "--show-call"), i + 1 < args.count {
            call.seedDemo(state: args[i + 1])
        }
        if let i = args.firstIndex(of: "--chat"), i + 1 < args.count {
            preselectID = args[i + 1]
        } else if args.contains("--show-code") {
            preselectID = DemoData.richID
        } else if showHistory {
            preselectID = DemoData.historyID
        } else if args.contains("--show-reply") {
            preselectID = DemoData.repliesID
        } else if args.contains("--show-pins") {
            preselectID = DemoData.avaID
        } else if args.contains("--show-saved") {
            preselectID = DemoData.avaID
        } else if args.contains("--demo-showcase") {
            preselectID = DemoData.showcaseID
        } else if args.contains("--demo-rich") {
            preselectID = DemoData.richID
        } else if args.contains("--demo-reactions") {
            preselectID = DemoData.reactionsID
        } else if args.contains("--demo-botposts") {
            preselectID = DemoData.botpostsID
        } else if args.contains("--show-popout") {
            preselectID = DemoData.demoID
        } else {
            preselectID = nil
        }
        if let i = args.firstIndex(of: "--name"), i + 1 < args.count {
            preselectName = args[i + 1]
        } else {
            preselectName = nil
        }
        if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
            autoSay = args[i + 1]
        } else {
            autoSay = nil
        }
        if let i = args.firstIndex(of: "--demo-arrive-after"), i + 1 < args.count {
            arriveAfter = Double(args[i + 1])
        } else {
            arriveAfter = nil
        }
        if let i = args.firstIndex(of: "--demo-arrive-text"), i + 1 < args.count {
            arriveText = args[i + 1]
        } else {
            arriveText = nil
        }
        arriveEdit = args.contains("--demo-arrive-edit")
        if let i = args.firstIndex(of: "--popout-chat"), i + 1 < args.count {
            popoutShotID = args[i + 1]
        } else {
            popoutShotID = nil
        }
        showPopout = args.contains("--show-popout")
        let initialBlocked = isDemo ? BlockedStore(defaults: nil) : BlockedStore()
        blocked = initialBlocked
        messageSearch = isDemo
            ? MessageSearchStore(searcher: { query, _, _ in
                DemoData.messageSearchResponse(for: query)
            })
            : MessageSearchStore()
        // gap-g6g7: offline-first merge + index writer hooks. Demo
        // attaches too (demo threads index via showDemo; fixtures
        // merge above local extras the same way).
        messageSearch.local = localSearch
        searchIndexAccountID = accounts.activeID ?? AccountProfile.defaultID
        do {
            try localSearch.loadDefault(for: searchIndexAccountID)
            searchIndexDocs = localSearch.docCount
        } catch {
            searchIndexError = "index load: \(error)"
        }
        // (conv.onHistory/onDelete wire in wireSearchIndex below —
        // closures capture self, which isn't ready this early.)
        filePeople = isDemo
            ? FilePeopleSearchStore(
                fileSearcher: { query, _ in DemoData.fileSearchResponse(for: query) },
                peopleSearcher: { query, _ in DemoData.peopleSearchResponse(for: query) })
            : FilePeopleSearchStore()
        // Shot hook: --show-contacts adopts the demo directory + one
        // speed-dial pin into a throwaway suite (never the real pins).
        if isDemo, args.contains("--show-contacts") {
            let suite = UserDefaults(suiteName: "shot-contacts") ?? .standard
            suite.removePersistentDomain(forName: "shot-contacts")
            let shot = ContactsStore(
                peopleSearcher: { query, _ in
                    DemoData.peopleSearchResponse(for: query)
                },
                defaults: suite)
            let demo = DemoData.peopleSearchResponse(for: "").people
            shot.adopt(demo)
            if let tom = demo.first(where: { $0.userId == "demo-u-tom" }) {
                shot.pin(tom)
            }
            contacts = shot
        } else {
            contacts = isDemo
                ? ContactsStore(peopleSearcher: { query, _ in
                    DemoData.peopleSearchResponse(for: query)
                })
                : ContactsStore()
        }
        contacts.presence = presence
        // d1-folders shot hooks: throwaway folders + rules (never the
        // real ones), preselecting Work unless the manager sheet owns
        // the shot.
        let folderStore: FolderStore
        if args.contains("--show-folders") || args.contains("--show-folders-manage") {
            let suite = UserDefaults(suiteName: "shot-folders") ?? .standard
            suite.removePersistentDomain(forName: "shot-folders")
            let seeded = FolderStore(defaults: suite)
            let work = seeded.createFolder(name: "Work")
            let family = seeded.createFolder(name: "Family")
            if let work {
                seeded.addRule(FolderRule(folderID: work.id, namePattern: "standup"))
            }
            if let family {
                seeded.addRule(FolderRule(folderID: family.id, kind: .direct))
                seeded.assign(chatID: DemoData.avaID, folderID: family.id)
            }
            folderStore = seeded
            folderShotSelection = args.contains("--show-folders-manage") ? nil : work?.id
            folderShotEditingRuleID = args.contains("--show-folders-manage")
                ? seeded.rules.first?.id : nil
        } else {
            folderStore = FolderStore()
            folderShotSelection = nil
            folderShotEditingRuleID = nil
        }
        var seedHistoryDemo = false
        if isDemo {
            // Shot hook: the churn dataset swaps the whole list (the
            // standard demo rows + count assertions stay untouched).
            let seed = showSidebarChurn
                ? DemoData.churnChatsResponse() : DemoData.chatsResponse()
            chats = ChatListViewModel(
                fetcher: { _ in seed },
                leaver: { LeaveResponse(ok: true, chat_id: $0) },
                blocked: initialBlocked,
                folders: folderStore)
            teams = TeamsViewModel(
                fetcher: { DemoData.teamsResponse() },
                creator: { _, name, _ in
                    ChannelCreateResponse(
                        ok: true,
                        channel: TeamChannel(
                            channelId: "demo-channel-\(name)", name: name))
                })
            reminders = RemindersViewModel(
                listsFetcher: { DemoData.remindersResponse() },
                tasksFetcher: { DemoData.reminderTasksResponse(for: $0) },
                localEdits: true)
            planner = PlannerViewModel(
                teamsFetcher: { DemoData.teamsResponse() },
                plansFetcher: { PlannerDemo.plansResponse(for: $0) },
                bucketsFetcher: { PlannerDemo.bucketsResponse(for: $0) },
                tasksFetcher: { PlannerDemo.tasksResponse(for: $0) },
                localEdits: true)
            recordings = RecordingsViewModel(
                listFetcher: { RecordingsDemo.response() },
                searchFetcher: { RecordingsDemo.searchResponse(for: $0) },
                downloadFetcher: { _, _, _ in try DemoClip.url().path })
            transcripts = TranscriptsViewModel(
                listFetcher: { TranscriptsDemo.response() },
                searchFetcher: { TranscriptsDemo.searchResponse(for: $0) },
                downloadFetcher: { _, _, dest in
                    try TranscriptsDemo.sampleVTT.write(
                        toFile: dest, atomically: true, encoding: .utf8)
                    return dest
                },
                recordingLookup: Self.demoRecordingLookup(),
                actionItemsTransport: args.contains("--show-transcripts-actions")
                    ? OnDeviceCatchUpTransport(
                        runner: OnDeviceMockRunner(stub: Self.actionItemsTranscriptStub),
                        availability: { .available })
                    : nil)
            // Parse stays real (pure core, no network); the join runner
            // echoes an accepted signaling leg so the lobby flow runs.
            meetings = MeetingsViewModel(
                meetingsFetcher: { DemoData.meetingsResponse() },
                joinRunner: { DemoData.demoJoinResult(threadID: $0) })
            calWeek = CalendarWeekStore(
                weekFetcher: { _ in Self.calWeekDemoResponse() },
                localEdits: true)
            shifts = ShiftsStore(week: { Self.shiftsDemoResponse(teamID: $0) })
            presence.adoptOwn(DemoData.ownPresence())
            for (chatID, peer) in DemoData.peerPresence() {
                presence.adoptChatPeer(chatID: chatID, response: peer)
            }
            for peer in DemoData.contactPresence() {
                presence.adoptPeer(peer)
            }
            mentions.adopt(DemoData.mentionedChatIDs)
            activity.seedDemo() // canned feed (in-memory, offline)
            seedHistoryDemo = true // applied after init (two-phase)
        } else {
            chats = ChatListViewModel(blocked: initialBlocked)
            teams = TeamsViewModel()
            reminders = RemindersViewModel()
            planner = PlannerViewModel()
            let liveRecordings = RecordingsViewModel()
            recordings = liveRecordings
            transcripts = TranscriptsViewModel(recordingLookup: { [weak liveRecordings] stem in
                liveRecordings?.items.first { TranscriptItem.stem(of: $0.name) == stem }
            })
            meetings = MeetingsViewModel()
            calWeek = CalendarWeekStore()
            shifts = ShiftsStore()
        }
        if seedHistoryDemo {
            history.seedDemo() // canned recents (in-memory, offline)
        }
        wireChats()
        wireSearchIndex() // gap-g6g7: history + delete → offline index
        popouts.bind(main: conv) // e1-popout: send mirroring both ways
        // e2-attention: manual picker sets pause the schedule until
        // the next window boundary (contract (i)). top10-presence chains
        // the truth note (echo labeled manual, idle disarmed). Weak.
        presence.manualSetHook = { [weak schedule = presenceSchedule, weak truth = presenceTruth] in
            schedule?.noteManualSet()
            truth?.noteManualSet()
        }
        // Single reaction point for the gate: every auth transition
        // (gate, Settings, Auth window — same model) runs authChanged,
        // which flips the gate via the signedIn/contentOpened flags.
        auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                Task { @MainActor [weak self] in self?.authChanged(s) }
            }
            .store(in: &cancellables)
        // om-s7-tickstorm: NO objectWillChange forwards — every surface
        // observes its store directly (Diagnostics sub-rows, CallBanner
        // incl. the auto-open trigger, sidebar, sheets, Settings), so a
        // store tick re-renders that surface only, never the root.
        // (Was: receipts/call/history/quietHours/chats forwards.)
        wireHistory()
        // e1-activity: reviewing the last mention for a chat clears
        // the MentionStore flag (shared review state, no orphans).
        activity.onMentionFlagsCleared = { [weak self] chatID in
            Task { @MainActor [weak self] in
                self?.mentions.markRead(chatID: chatID)
            }
        }
        call.$call
            .receive(on: DispatchQueue.main)
            .sink { [weak self] c in
                Task { @MainActor [weak self] in
                    self?.history.noteActiveCall(c)
                }
            }
            .store(in: &cancellables)
        // gap-g3: incoming rings bell the OS (live only — demo/shots
        // stay silent and banner-free). The hooks fire on the phase
        // machine's transitions; Notifier owns the banner itself.
        if !isDemo {
            call.ringer = CallRinger()
            call.onIncomingRing = { info in
                let peer = info.displayPeer
                Notifier.shared.postCall(
                    title: peer.isEmpty ? "Unknown caller" : peer,
                    body: "Incoming call", callID: info.id)
            }
            call.onRingEnded = { id in
                Notifier.shared.withdrawCall(callID: id)
            }
        }
        // om-notif: banner click opens the chat; inline reply sends.
        // gap-g1: background banners carry their owning account — open
        // switches to it first, reply sends on it (never the active one).
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifOpenChat, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?["chatID"] as? String else { return }
            let acct = note.userInfo?["accountID"] as? String
            Task { @MainActor [weak self] in
                self?.openFromNotification(chatID: id, accountID: acct)
            }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifReply, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?["chatID"] as? String,
                  let text = note.userInfo?["text"] as? String
            else { return }
            let acct = note.userInfo?["accountID"] as? String
            Task { @MainActor [weak self] in
                self?.sendFromNotification(chatID: id, text: text, accountID: acct)
            }
        }
        // gap-g3: call-banner actions (Accept/Decline/click). Decline is
        // end() — CallStore counts an ended incoming ring as a decline.
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifAcceptCall, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.call.accept() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifDeclineCall, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.call.end() }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifShowCall, object: nil, queue: nil
        ) { _ in
            Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
        }
        // top10-presence: screen lock/sleep feed activity truth (Away
        // while locked is legitimate — and now labeled as such).
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteSleep() }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteWake() }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteScreenLock() }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceTruth.noteScreenUnlock() }
        }
        // f1-composer: global hotkey → floating composer; Settings
        // toggle/remap/reset re-registers without a relaunch.
        quickComposeHotKey.onFire = { [weak self] in
            Task { @MainActor [weak self] in self?.summonComposer() }
        }
        applyQuickComposePrefs()
        NotificationCenter.default.publisher(for: .quickComposePrefsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyQuickComposePrefs() }
            }
            .store(in: &cancellables)
        // d1-accounts: ordered switch stages (drain → flip → reset →
        // resume). Demo never switches (single canned identity).
        accounts.hooks = AccountSwitchHooks(
            drainRealtime: { [weak self] in self?.feed.stop() },
            resetForAccount: { [weak self] record in
                self?.resetStoresForAccount(record)
            },
            resume: { [weak self] in self?.repointAuthToActive() },
            removeCaches: { [weak self] record in
                AccountCaches.remove(accountID: record.id)
                // gap-g1: the removed account leaves the background
                // set (snapshot + roll-up stash dropped with it).
                self?.bgPoller.drop(accountID: record.id)
                self?.bgRollup.drop(accountID: record.id)
                // gap-g2: its window graph goes too (a live window
                // renders the removed placeholder).
                self?.accountWindows.drop(accountID: record.id)
            },
            emptied: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.auth.refreshStatus()
                }
            }
        )
        ColdStart.mark("appstate.init") // top10-menubar: launch timeline
    }

    /// Chat-list satellite wiring (local-remove fan-out + selection
    /// sink). Re-run after every `chats` rebuild (account switch).
    private func wireChats() {
        chatsCancellables = Set<AnyCancellable>()
        // om-leave-block: a locally-removed row drops its satellite
        // state (unread, mention flags) — never a list refresh.
        chats.onLocalRemove = { [weak self] id in
            self?.unread.markRead(chatID: id)
            self?.mentions.markRead(chatID: id)
        }
        chats.$selectedChatID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                Task { @MainActor [weak self] in self?.openSelected(id) }
            }
            .store(in: &chatsCancellables)
    }

    /// Offline-index writer wiring (gap-g6g7): fetched history
    /// batches + confirmed deletes flow into `localSearch`. The
    /// closures hop to MainActor (ConversationStore is unisolated).
    private func wireSearchIndex() {
        conv.onHistory = { [weak self] chatID, msgs in
            Task { @MainActor [weak self] in
                self?.indexHistory(chatID: chatID, messages: msgs)
            }
        }
        conv.onDelete = { [weak self] chatID, id in
            Task { @MainActor [weak self] in
                self?.dropIndexed(chatID: chatID, messageID: id)
            }
        }
    }

    /// Call-history redial wiring (re-run after rebuild).
    private func wireHistory() {
        history.onRedial = { [weak self] record in
            Task { @MainActor [weak self] in self?.redial(record) }
        }
        // e1-activity: missed calls land in the feed (re-wired per
        // account alongside redial — the store is rebuilt on switch).
        history.onRecord = { [weak self] record in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activity.noteCallRecord(
                    record,
                    chatName: self.chatNameOrNil(for: record.thread)
                        ?? record.displayName)
            }
        }
    }

    // MARK: - Accounts (d1-accounts)

    /// Live chat list for one account (per-account pins/folders/blocked
    /// namespaces; default keeps the legacy keys).
    private func makeChats(accountID: String, blocked: BlockedStore) -> ChatListViewModel {
        ChatListViewModel(
            blocked: blocked,
            folders: FolderStore(accountID: accountID))
    }

    /// Meeting chat for one account (per-account persistence namespace).
    private func makeMeetingChat(accountID: String) -> MeetingChatStore {
        MeetingChatStore(
            load: { MeetingChatStore.fileLoad(threadID: $0, for: accountID) },
            save: { MeetingChatStore.fileSave(threadID: $0, messages: $1, for: accountID) },
            delete: { MeetingChatStore.fileDelete(threadID: $0, for: accountID) })
    }

    /// Switch stage 3 (runs inside AccountStore.switchTo, after the core
    /// profile flips): rebuild per-account stores + drop every
    /// identity-bound row. Sync; actor-cache resets kick Tasks.
    private func resetStoresForAccount(_ record: AccountRecord) {
        let id = record.id
        openChatID = nil
        ownerMRI = nil
        conv.resetForAccount(displayName: record.displayName)
        chats.resetForAccount()
        let freshBlocked = isDemo
            ? BlockedStore(defaults: nil)
            : BlockedStore(key: BlockedStore.key(for: id))
        blocked = freshBlocked
        chats = makeChats(accountID: id, blocked: freshBlocked)
        wireChats()
        pinnedMessages = PinnedMessageStore(key: PinnedMessages.key(for: id))
        savedMessages = SavedMessageStore(key: SavedMessages.key(for: id))
        history = CallHistoryStore(key: CallHistoryStore.key(for: id))
        wireHistory()
        meetingChat = makeMeetingChat(accountID: id)
        switchSearchIndex(to: id) // gap-g6g7: per-account offline index
        messageSearch.clear() // gap-g6g7: stale hits never cross accounts
        teams.resetForAccount()
        presence.clear()
        presenceSchedule.clearApplied() // e2-attention: drop applied state
        presenceTruth.clearSession() // top10-presence: drop lock/log/devices
        typing.clear()
        meeting.clear()
        unread.markAllRead()
        // gap-g1 switch handoff: arrivals accrued while this account was
        // inactive land in the live store, so the switch shows unread N.
        unread.ingestBackground(bgRollup.take(accountID: id))
        mentions.markAllRead()
        receipts.clear()
        ghost.clear() // f1-ghost: counters clear, toggles persist
        Task {
            await RichMediaCache.shared.resetForAccount(id)
            await LinkPreviewCache.shared.resetForAccount()
        }
    }

    /// Switch stage 4: rebind the live gate VM to the new active profile
    /// and re-read status (pure read; `.signedIn` lands the quiet
    /// reload via authChanged). Runs for switch + remove-active
    /// fallthrough.
    private func repointAuthToActive() {
        guard let id = accounts.activeID else { return }
        switchingAccount = true
        auth.repoint(profile: id)
        Task { await auth.refreshStatus() }
    }

    /// Switch accounts (switcher menu). No-op in demo, for the active
    /// id, and for unknown ids.
    func switchAccount(to id: String) {
        guard !isDemo else { return }
        guard id != accounts.activeID else { return }
        guard accounts.accounts.contains(where: { $0.id == id }) else { return }
        accounts.switchTo(id)
    }

    /// Remove one account (Settings). The store runs drain → core
    /// sign-out → cache wipe; active removal falls through to the next
    /// account (or empties, which re-reads status → gate closes).
    func removeAccount(_ id: String) {
        guard !isDemo else { return }
        accounts.removeAccount(id)
    }

    /// Finish an add-account sheet sign-in: resolve identity on the new
    /// profile, record + activate the account, re-stamp every store,
    /// and rebind the gate VM. Feed restarts via the quiet path.
    func completePendingAdd(_ vm: AuthViewModel) {
        guard !isDemo else { return }
        Task {
            let profile = vm.profile
            let me = try? await Task.detached {
                try RustCore.whoami(profile: profile)
            }.value
            let name: String
            if let display = me?.display_name, !display.isEmpty {
                name = display
            } else {
                name = "Account \(accounts.accounts.count + 1)"
            }
            feed.stop()
            guard accounts.completeAdd(
                profile: profile, displayName: name,
                upn: me?.mail, userID: me?.id)
            else { return }
            guard let record = accounts.accounts.first(where: { $0.id == profile })
            else { return }
            resetStoresForAccount(record)
            repointAuthToActive()
        }
    }

    /// Adopt the legacy single-account session after upgrade (or a fresh
    /// first sign-in): the default profile becomes the first account.
    private func adoptLegacyAccount() async {
        guard accounts.accounts.isEmpty else { return }
        let me = try? await Task.detached { try RustCore.whoami() }.value
        let name: String
        if let display = me?.display_name, !display.isEmpty {
            name = display
        } else {
            name = "Account 1"
        }
        accounts.adoptLegacy(displayName: name, upn: me?.mail, userID: me?.id)
        accounts.refreshAll()
    }

    /// Post-switch reload without spinners: quiet list fetches (state
    /// only moves when rows land), presence + owner MRI re-resolve,
    /// background tab refreshes, then realtime resumes on the new
    /// profile (feed.start drains stale backlog silently).
    private func quietRefreshAfterSwitch() {
        Task {
            await chats.loadQuietly()
            await teams.loadQuietly()
            await presence.refreshOwn()
            resolveOwnerMRI()
            reminders.refresh()
            planner.refresh()
            recordings.refresh()
            transcripts.refresh()
            meetings.refresh()
            calWeek.refresh()
            if shifts.selectedTeamID == nil {
                seedShifts()
            } else {
                shifts.refresh()
            }
            if !isDemo {
                feed.start()
            }
            refreshFeedStatus()
        }
    }

    func startup() async {
        guard !started else { return }
        started = true
        coreVersion = RustCore.version()
        initCode = RustCore.initialize()
        if isDemo {
            signedIn = true // demo bypasses the gate (offline canned data)
        } else {
            // d1-accounts: relaunch restores the last-active profile
            // BEFORE the status read (gate + whoami follow it).
            // gap-g2: routed through the gate (records + serializes;
            // no window op can exist yet, but the record must be true).
            if let active = accounts.activeID {
                _ = try? profileGate.setActive(active) {
                    try RustCore.profileSet($0)
                }
                auth.repoint(profile: active)
            }
            await auth.refreshStatus()
            signedIn = auth.isSignedIn
            accounts.refreshAll()
        }
        await openContentIfAllowed()
        // top10-menubar: launch timeline close + media-deferral proof.
        ColdStart.mark("startup.done")
        print("[coldstart] \(ColdStart.mediaInitReport())")
        fflush(stdout)
        if CommandLine.arguments.contains("--coldstart-quit") {
            // Proof hook: clean exit once the timeline lands (flushed).
            // Waits for the first chat open (join-ready) up to 30s —
            // the selection sink lands just after startup.done.
            Task {
                for _ in 0..<300 where !ColdStart.hasMarked("chat.first-open") {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                print("[coldstart] \(ColdStart.report().replacingOccurrences(of: "\n", with: " | "))")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    /// Post-gate: chats + restore + feed + autosay. Runs once, only when
    /// demo or signed in. authChanged(.signedIn) retries after the gate
    /// opens, so a gated launch defers everything (no unsigned core calls
    /// beyond the read-only status check).
    private func openContentIfAllowed() async {
        guard !contentOpened, isDemo || auth.state.allowsContent else { return }
        contentOpened = true
        await chats.load()
        if showSidebarChurn {
            // Shot hook: fold the beacon burst once the list lands; the
            // sidebar (not the thread) shows the stable result.
            chats.ingest(batch: DemoData.churnBurst())
        }
        await teams.load()
        await reminders.load()
        await planner.load()
        await recordings.load()
        if CommandLine.arguments.contains("--show-recordings-playing") {
            recordings.selectAndPlayFirst()
        }
        await transcripts.load()
        if CommandLine.arguments.contains("--show-transcripts-showing")
            || CommandLine.arguments.contains("--show-transcripts-actions")
        {
            transcripts.autoExtractActionItems =
                CommandLine.arguments.contains("--show-transcripts-actions")
            transcripts.selectAndShowFirst()
        }
        // top10-menubar: the meeting list loads on first Meetings-window
        // open (that scene already refresh()es on appear) — never on the
        // launch path.
        seedShifts() // team picker + first-week grid (demo + live)
        if chats.state == .loaded {
            // Core's signed_in is aad-centric; a loaded list proves
            // working auth regardless.
            signedIn = true
        }
        // Restore (om-demo-select): explicit --chat wins, else the last
        // selection — resolved against the loaded list, never blind. A
        // restored id absent from the list falls back to the first chat
        // (no direct open, no 404); demo threads never load outside the
        // demo flags.
        let action = SelectionRestore.resolve(
            explicit: preselectID, restored: persistedSelection,
            chats: chats.chats, isDemo: isDemo)
        if !isDemo, let stale = persistedSelection, DemoData.isDemoID(stale) {
            persistedSelection = nil // scrub pre-fix demo default
        }
        switch action {
        case .select(let id):
            // e1-inwindow: a hook-armed pane shows INSTEAD of the
            // restored selection (explicit --chat still wins below —
            // `open` clears the pane).
            if activityPane == nil {
                chats.selectedChatID = id // sink opens it
            }
        case .openDirect(let id):
            open(chatID: id, chatName: preselectName)
        case .none:
            break
        }
        if showPopout, pendingPopoutID == nil {
            // Shot hook: pop a second chat beside the main selection
            // (explicit --popout-chat wins, else the first other row).
            let mainID: String? = switch action {
            case .select(let id): id
            case .openDirect(let id): id
            case .none: openChatID
            }
            let fallback = chats.chats.first { $0.id != mainID }?.id
                ?? chats.chats.first?.id
            pendingPopoutID = popoutShotID ?? fallback ?? DemoData.avaID
        }
        if !isDemo {
            presence.refreshOwnSoon() // own dot; non-critical on failure
            setupNotifier() // om-rules: banners for filtered live events
            resolveOwnerMRI() // async; name backup covers the gap
            feed.subscribe { [weak self] msg in
                Task { @MainActor [weak self] in self?.handleRealtime(msg) }
            }
            feed.onResync { [weak self] in
                Task { @MainActor [weak self] in self?.handleResync() }
            }
            feed.onCall { [weak self] ev in
                Task { @MainActor [weak self] in
                    self?.handleCall(ev)
                    self?.history.noteEvent(ev)
                }
            }
            feed.onTyping { [weak self] ev in
                Task { @MainActor [weak self] in self?.handleTyping(ev) }
            }
            feed.onRoster { [weak self] ev in
                Task { @MainActor [weak self] in self?.handleRoster(ev) }
            }
            // Single shared response delegate (routes both banner
            // families; installed after Notifier.setup so it wins).
            notifs.attach()
            await notifs.requestAuthorization()
            feed.start()
            // gap-g1: background sweep over inactive accounts (first
            // sweep seeds silently — no launch banner storm).
            startBackgroundPoll()
        }
        if let say = autoSay {
            if openChatID == nil, isDemo, let first = chats.chats.first {
                chats.selectedChatID = first.id
                open(chatID: first.id, chatName: first.name)
            }
            if openChatID != nil {
                conv.send(text: say)
            }
        }
        if showNotifLive, isDemo {
            Task { await runNotifLiveProof() }
        }
        if isDemo, let secs = arriveAfter {
            // Perf-harness delay hook (demo-only): peer arrival AFTER
            // settle through the REAL live path (handleRealtime), into
            // the OPEN chat so frames show the bubble delta.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                await MainActor.run { self?.injectArrival() }
            }
        }
        // The 2s tick runs in demo too (d2-send: the scheduled queue and
        // the snooze sweep are client-side in both modes; the tick
        // publishes nothing while idle, so demo stays still). Starts
        // after the open above so launch catch-up delivers into the
        // open chat (own-bubble) instead of racing it.
        refreshFeedStatus()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        ColdStart.mark("content.open") // top10-menubar: launch timeline
    }

    /// Offline banner proof (om-notif-live --show-notif-live): one canned
    /// trouter event through the REAL live path (handleRealtime: rules →
    /// banner). Logs NOTIFLIVE lines (auth, injection, decision, posted
    /// note, delivered readback, counters) to stdout and a temp JSONL
    /// file the shot runner collects. Never touches core/network: demo
    /// chats resolve the name, the fixture targets a non-open chat (no
    /// receipts/presence calls), and the toggle is restored afterwards.
    private func runNotifLiveProof() async {
        setupNotifier()
        notifs.attach()
        let status = await Notifier.shared.authorizationStatus()
        let statusName: String = switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown(\(status.rawValue))"
        }
        let wasEnabled = notifs.enabled
        notifs.enabled = true
        logNotifLive("auth status=\(statusName) toggle-was=\(wasEnabled ? "on" : "off")")
        let msg = RealtimeMessage(
            chatID: DemoData.avaID, msgId: "notiflive-1",
            sender: "Ava Lindqvist",
            text: "Are we still on for 10?",
            time: "2026-09-24T05:00:00Z",
            isEdit: false, messageType: "Text")
        logNotifLive("inject chatID=\(msg.chatID) msgId=\(msg.msgId) sender=\(msg.sender)")
        handleRealtime(msg)
        logNotifLive("decision posted=\(notifPosted) skipped=\(notifSkipped) last=\(notifLastReason)")
        // The center delivers async; poll briefly for the readback.
        var found: UNNotification?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let all = await UNUserNotificationCenter.current().deliveredNotifications()
            if let hit = all.first(where: { $0.request.identifier == msg.msgId }) {
                found = hit
                break
            }
        }
        if let hit = found {
            logNotifLive("delivered id=\(hit.request.identifier) title=\(hit.request.content.title) body=\(hit.request.content.body)")
        } else {
            let all = await UNUserNotificationCenter.current().deliveredNotifications()
            logNotifLive("delivered MISS ids=\(all.map(\.request.identifier))")
        }
        logNotifLive("done posted=\(notifPosted) skipped=\(notifSkipped) last=\(notifLastReason)")
        notifs.enabled = wasEnabled
    }

    /// One proof line: stdout (direct launches) + temp JSONL (open(1)
    /// launches, where stdout goes to Console). Best-effort file append.
    private func logNotifLive(_ line: String) {
        print("NOTIFLIVE \(line)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-notif-live-proof.jsonl")
        let entry = "{\"t\":\"\(Date().timeIntervalSince1970)\",\"line\":\"\(line.replacingOccurrences(of: "\"", with: "'"))\"}\n"
        if let data = entry.data(using: .utf8),
           let fh = try? FileHandle(forWritingTo: url)
        {
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
            try? fh.close()
        } else if let data = entry.data(using: .utf8) {
            try? data.write(to: url)
        }
    }

    /// Delayed peer arrival (perf-harness hook): like runNotifLiveProof
    /// but targets the OPEN chat so capture frames show the bubble
    /// delta. Logs ARRIVE lines (stdout + temp JSONL, logNotifLive
    /// pattern). --demo-arrive-edit retexts the bubble +2s.
    private func injectArrival() {
        let target = openChatID ?? preselectID ?? DemoData.demoID
        let sender = "Ava Lindqvist"
        guard sender != conv.ownDisplayName else {
            logArrive("skip own-name sender=\(sender)")
            return
        }
        let msg = RealtimeMessage(
            chatID: target, msgId: "arrive-1",
            sender: sender,
            text: arriveText ?? "Sounds good — see you at 10",
            time: "2026-09-26T00:00:00Z",
            isEdit: false, messageType: "Text")
        logArrive("inject chatID=\(msg.chatID) msgId=\(msg.msgId) open=\(openChatID ?? "nil")")
        handleRealtime(msg)
        logArrive("done posted=\(notifPosted) skipped=\(notifSkipped) last=\(notifLastReason)")
        if arriveEdit {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.injectArrivalEdit(target: target, sender: sender)
                }
            }
        }
    }

    /// Arrival-edit follow-up: in-place retext of the injected bubble.
    private func injectArrivalEdit(target: String, sender: String) {
        let msg = RealtimeMessage(
            chatID: target, msgId: "arrive-1-edit",
            sender: sender,
            text: (arriveText ?? "Sounds good — see you at 10") + " (edited)",
            time: "2026-09-26T00:00:02Z",
            isEdit: true, editedID: "arrive-1", messageType: "Text")
        logArrive("inject-edit chatID=\(msg.chatID) editedID=arrive-1 open=\(openChatID ?? "nil")")
        handleRealtime(msg)
    }

    /// ARRIVE proof line: stdout + temp JSONL (logNotifLive pattern).
    private func logArrive(_ line: String) {
        print("ARRIVE \(line)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-arrive-proof.jsonl")
        let entry = "{\"t\":\"\(Date().timeIntervalSince1970)\",\"line\":\"\(line.replacingOccurrences(of: "\"", with: "'"))\"}\n"
        if let data = entry.data(using: .utf8),
           let fh = try? FileHandle(forWritingTo: url)
        {
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
            try? fh.close()
        } else if let data = entry.data(using: .utf8) {
            try? data.write(to: url)
        }
    }

    func shutdown() {
        stateTimer?.invalidate()
        stateTimer = nil
        bgTimer?.invalidate()
        bgTimer = nil
        feed.stop()
    }

    /// Sidebar selection changed (nil = cleared).
    private func openSelected(_ id: String?) {
        guard let id else {
            openChatID = nil
            conv.close() // never show a dead thread behind the empty detail
            return
        }
        guard id != openChatID else {
            // Already open (direct --chat path): still republish so
            // selection-driven body reads (isGroup) refresh — there is
            // no chats forward anymore. Redundant sets only.
            objectWillChange.send()
            return
        }
        let name = chats.chat(id: id)?.name ?? preselectName
        open(chatID: id, chatName: name)
    }

    /// Teams browser: a channel opens as a conversation through the same
    /// path as chats (channel ids are conversation ids, ost TUI parity).
    func openChannel(channelID id: String, channelName: String) {
        open(chatID: id, chatName: channelName)
    }

    /// Bubble Forward tap (om-msgactions): arm the forward sheet (the
    /// palette opens for this bubble; picking sends via conv.forward).
    func beginForward(_ message: ChatMessage) {
        forwardMessage = message
    }

    // MARK: - Quick composer (f1-composer)

    /// Reconcile the global hotkey with prefs (launch + every Settings
    /// toggle/remap/reset — no relaunch).
    func applyQuickComposePrefs() {
        _ = quickComposeHotKey.update(
            combo: QuickComposerPrefs.loadCombo(),
            enabled: QuickComposerPrefs.isEnabled())
    }

    /// Summon the floating composer (global hotkey, Go menu, shot hook).
    func summonComposer() {
        if composerPanel == nil { composerPanel = QuickComposerPanelController() }
        let signedIn = isDemo || auth.state.allowsContent
        let preseed = quickComposePreseed
        quickComposePreseed = nil // one-shot: later summons are blank
        composerPanel?.summon(
            chats: chats, teams: teams, signedIn: signedIn,
            initialTargetQuery: preseed?.query, initialMessage: preseed?.text,
            initialPickFirst: preseed?.pickFirst ?? false
        ) { [weak self] id, name, text in
            self?.quickSend(targetID: id, targetName: name, text: text)
        }
    }

    /// Post one quick message. Open target → the open ConversationStore
    /// (the optimistic own-bubble lands in the main-window timeline);
    /// off-screen target → direct core send (demo records locally).
    /// Never changes the selection, never refetches — zero-refresh.
    func quickSend(targetID: String, targetName: String, text: String) {
        let body = CodeBlocks.sendBody(for: text)
        guard !body.isEmpty else { return }
        if QuickComposerRouting.sendThroughOpenStore(
            targetID: targetID, openChatID: conv.chatID)
        {
            conv.send(text: body)
            return
        }
        if isDemo {
            lastQuickSend = QuickSendRecord(
                targetID: targetID, targetName: targetName, text: body,
                failed: false, error: nil)
            return
        }
        Task {
            do {
                let (id, content) = (targetID, body)
                _ = try await Task.detached {
                    try RustCore.send(chatID: id, text: content)
                }.value
                self.lastQuickSend = QuickSendRecord(
                    targetID: targetID, targetName: targetName, text: body,
                    failed: false, error: nil)
            } catch {
                self.lastQuickSend = QuickSendRecord(
                    targetID: targetID, targetName: targetName, text: body,
                    failed: true, error: "\(error)")
            }
        }
    }

    /// Forward palette pick: send the armed bubble's text to the
    /// destination, then disarm. No-op without an armed bubble.
    func forwardPicked(destID: String, destName: String) {
        guard let msg = forwardMessage else { return }
        forwardMessage = nil
        conv.forward(msg, toChatID: destID, destName: destName)
    }

    /// Recents redial (om-call-history): re-place on the record's
    /// thread. No-op without a thread (incoming legs carry none) or
    /// while another call is active.
    func redial(_ record: CallRecord) {
        let thread = record.thread.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !thread.isEmpty else { return }
        guard !(call.call?.isActive ?? false) else { return }
        call.place(threadID: thread)
    }

    /// Jump palette: chats route through the sidebar selection (keeps the
    /// list highlight in sync); channels/teams open directly by id.
    func jump(chatID id: String, chatName: String) {
        if chats.chats.contains(where: { $0.id == id }) {
            chats.selectedChatID = id // sink opens it (or already open)
            if openChatID == nil { open(chatID: id, chatName: chatName) }
        } else {
            open(chatID: id, chatName: chatName)
        }
    }

    /// Message-hit jump (om-ja-search): open the hit's conversation, then
    /// land on the bubble. Already-open threads seek in place (no
    /// reload); other threads open with the seek armed (bounded
    /// page-back, then the timeline jumps).
    func jumpToMessage(_ hit: SearchHit) {
        showJump = false
        if hit.chatID == openChatID {
            conv.seek(messageID: hit.messageID)
            return
        }
        pendingSeekMessageID = hit.messageID
        jump(chatID: hit.chatID, chatName: displayName(for: hit.chatID))
    }

    /// Activity-row jump (e1-activity): open the row's chat, land on
    /// the message via the search funnel. Chat-only targets (missed
    /// calls) open without a seek; blank chat ids no-op (never conjure).
    func jumpToActivity(_ target: ActivityTarget) {
        guard target.canJump else { return }
        activityPane = nil // e1-inwindow: the jump lands on the chat
        guard let messageID = target.messageID else {
            jump(
                chatID: target.chatID,
                chatName: displayName(for: target.chatID))
            return
        }
        jumpToMessage(SearchHit(
            messageID: messageID, chatID: target.chatID,
            sender: "", timestamp: "", preview: ""))
    }

    /// Sidebar + channel name for one conversation id (hit subtitles and
    /// jump headers share it). Unknown ids fall back to the generic label.
    func displayName(for chatID: String) -> String {
        chatNameOrNil(for: chatID) ?? "Conversation"
    }

    /// Channel context for saves (e2-saved): the team/channel ids
    /// behind one chat id (nil pair for plain chats and unknown ids).
    func savedContext(for chatID: String) -> (teamID: String?, channelID: String?) {
        for team in teams.teams {
            if team.channels.contains(where: { $0.id == chatID }) {
                return (team.id, chatID)
            }
        }
        return (nil, nil)
    }

    /// Saved-row jump (e2-saved): close the sheet, then the standard
    /// message-hit funnel (open the chat + seek the bubble).
    func jumpToSaved(_ hit: SearchHit) {
        showSaved = false
        jumpToMessage(hit)
    }

    /// Name for one conversation id, nil when unknown (palette hit
    /// subtitles omit the chat rather than print the generic label).
    func chatNameOrNil(for chatID: String) -> String? {
        if let name = chats.chat(id: chatID)?.name { return name }
        for team in teams.teams {
            if let ch = team.channels.first(where: { $0.id == chatID }) {
                return "\(team.name) > #\(ch.name)"
            }
        }
        return nil
    }

    /// Pop-out entry (e1-popout): register the chat and return the window
    /// value for `openWindow(value:)` (re-pop refocuses — the registry
    /// enforces one window per id). Nil for blank ids. Popping marks the
    /// chat read (open-chat parity for unread + Mentions).
    func popOut(chatID: String) -> String? {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        popouts.pop(chatID: id)
        unread.markRead(chatID: id) // open-chat parity: popped is visible
        mentions.markRead(chatID: id)
        return id
    }

    /// Pop-out window name: list/teams name, else the static demo name,
    /// else the id itself (--chat direct-open precedent for chats
    /// missing from the list). The demo fallback matches the main
    /// `open` path and covers windows opened before the list lands.
    func popoutName(for chatID: String) -> String {
        chatNameOrNil(for: chatID)
            ?? (isDemo ? DemoData.name(for: chatID) : nil)
            ?? chatID
    }

    /// Open (once) a pop-out window's backing store: demo seeds canned
    /// messages, live loads through core. Cached per chat for the
    /// session — re-pop restores with no reload.
    func openPopout(chatID: String) {
        let s = popouts.store(for: chatID)
        guard s.chatID != chatID else { return }
        if isDemo {
            s.showDemo(
                chatID: chatID, chatName: popoutName(for: chatID),
                messages: DemoData.messages(for: chatID),
                failed: DemoData.failedIDs(for: chatID))
        } else {
            s.open(chatID: chatID, chatName: popoutName(for: chatID))
        }
    }

    // MARK: - Account windows (gap-g2)

    /// Flip-flop runner: one blocking core op under an inactive
    /// account's profile. Pauses the live feed first (no trouter poll
    /// may START mid-flip — a wrong-profile poll would misattribute
    /// events), then gated flip → op → flip-back → resume. The
    /// resume's backlog drain is silent, so `onResumed` closes the
    /// gap (refetch open chat + list). Skips the pause entirely when
    /// the feed is already stopped (signed out).
    private struct AccountWindowRunner: AccountCoreRunner {
        let gate: AccountProfileGate
        let feed: RealtimeFeed
        let onResumed: @Sendable () -> Void

        func run<T>(_ op: () throws -> T, accountID: String?) throws -> T {
            let wasLive = feed.currentState != .stopped
            if wasLive { feed.stop() }
            defer {
                if wasLive {
                    feed.start()
                    onResumed()
                }
            }
            return try gate.run(under: accountID, op) {
                try RustCore.profileSet($0)
            }
        }
    }

    /// Build one window graph: per-profile list reads + stamped conv
    /// with the flip-flop runner. Demo runs the memory blocked store
    /// (never the real defaults — main-window reset parity).
    private func makeAccountGraph(for record: AccountRecord) -> AccountWindowGraph {
        let runner = AccountWindowRunner(
            gate: profileGate, feed: feed
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.noteWindowOpResumed() }
        }
        let blocked = isDemo
            ? BlockedStore(defaults: nil)
            : BlockedStore(key: BlockedStore.key(for: record.id))
        let chats = ChatListViewModel(
            fetcher: { [id = record.id] in
                try RustCore.chats(limit: $0, profile: id)
            },
            blocked: blocked,
            folders: FolderStore(accountID: record.id))
        return AccountWindowGraph(
            account: record, chats: chats, runner: runner)
    }

    /// Side-by-side entry (switcher "Open in New Window"): register
    /// the account window and return the window value for
    /// `openWindow(value:)` (re-open refocuses — the registry
    /// enforces one window per id). Nil for blank/unknown ids.
    func openAccountWindow(accountID: String) -> String? {
        let id = accountID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard let record = accounts.accounts.first(where: { $0.id == id })
        else { return nil }
        accountWindows.open(accountID: id) { makeAccountGraph(for: record) }
        return id
    }

    /// Window closed: the graph's unread merges back into the
    /// background roll-up (a later switch still lands on unread N)
    /// and drains locally (never double-counted); the graph itself
    /// stays cached — re-open restores selection, bubbles, and pins
    /// with no reload.
    func closeAccountWindow(accountID: String) {
        if let g = accountWindows.graph(for: accountID) {
            bgRollup.ingest(g.unread.counts, for: accountID)
            g.unread.markAllRead()
        }
        accountWindows.close(accountID: accountID)
    }

    /// Flip-flop gap-close (coalesced): the pause's silent drain may
    /// have swallowed live events, so re-fetch the open chat + list.
    /// Leading-edge 2s throttle across rapid window ops.
    private func noteWindowOpResumed() {
        let now = Date()
        guard now.timeIntervalSince(lastWindowResync) > 2 else { return }
        lastWindowResync = now
        handleResync()
    }

    /// Armed message seek (om-ja-search): `jumpToMessage` sets it, `open`
    /// consumes it (even on the guard exits, so a refused open never
    /// leaks a stale seek into the next open).
    private var pendingSeekMessageID: String?

    /// File-hit pick (om-jb-filesearch): open the SharePoint page in
    /// the default browser (https only; hits without a URL no-op).
    func openSearchFile(_ file: SharedFile) {
        showJump = false
        guard let raw = file.web_url, let url = URL(string: raw),
            url.scheme == "https",
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            comps.host != nil
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Person-hit pick (om-lt5-person11): open the 1:1 chat with the
    /// picked person. Demo opens a canned thread; live creates (or
    /// re-opens) via core off-main, then opens. Hits without a user
    /// ref, and failed creates, fall back to the v1 behavior (copy
    /// the work email to the clipboard).
    func openSearchPerson(_ person: TeamMember) {
        showJump = false
        guard let ref = PersonChat.userRef(for: person) else {
            copyEmail(person.email)
            return
        }
        if isDemo {
            jump(
                chatID: PersonChat.demoChatID(for: person),
                chatName: person.displayName)
            return
        }
        let name = person.displayName
        let email = person.email
        Task { @MainActor [weak self] in
            let created: ChatCreateResponse? = try? await Task.detached {
                try RustCore.chatCreateOneToOne(user: ref)
            }.value
            guard let self, let chat = created?.chat else {
                self?.copyEmail(email)
                return
            }
            self.jump(chatID: chat.chatId, chatName: name)
        }
    }

    /// v1 fallback: copy one work email (hits without an email no-op).
    private func copyEmail(_ email: String?) {
        guard let email, !email.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
    }

    private func open(chatID id: String, chatName: String?) {
        let seek = pendingSeekMessageID
        pendingSeekMessageID = nil
        // Demo threads never load outside the demo flags (a stale
        // demo-react default 404d the installed build); demo
        // selections never reach shared defaults either.
        guard isDemo || !DemoData.isDemoID(id) else { return }
        // Blocked threads never open (jump/direct paths fail closed).
        guard !blocked.isBlocked(chatID: id) else { return }
        activityPane = nil // e1-inwindow: any open chat clears the pane
        openChatID = id
        // top10-menubar: join-ready = first chat open (one-shot).
        if !ColdStart.hasMarked("chat.first-open") {
            ColdStart.mark("chat.first-open")
        }
        if SelectionRestore.shouldPersist(chatID: id) {
            persistedSelection = id
        }
        unread.markRead(chatID: id) // om-notifbadge + om-markunread: opening marks read (counts + horizon override)
        mentions.markRead(chatID: id) // om-mentions: opening clears the flag
        activity.markChatReviewed(chatID: id) // e1-activity: opening reviews the feed rows
        if isDemo {
            // om-receipts: demo peers read through the tail (offline Seen).
            if let last = DemoData.messages(for: id).last {
                receipts.adopt(threadID: id, peers: ["demo-peer": last.id])
                receipts.noteSent(chatID: id, messageID: last.id)
            }
            let name = chatName ?? DemoData.name(for: id) ?? "Conversation"
            var msgs = DemoData.messages(for: id)
            if showCatchUp || showActionItems { msgs = Self.longThread(from: msgs) }
            // Shot hook: --show-code appends fenced-code bubbles to the
            // open thread (top10-code; demo only, DemoData untouched).
            if CommandLine.arguments.contains("--show-code") {
                msgs += Self.codeShotMessages(stamp: msgs.last?.timestamp ?? "2026-09-26T09:00:00Z")
            }
            // Shot hook: empty thread + canned fetch failure (offline).
            if showHistoryError {
                msgs = []
                conv.showDemo(chatID: id, chatName: name, messages: msgs)
                conv.seedDemoError("failed(\"messages: network unreachable\")")
            } else {
                conv.showDemo(
                    chatID: id, chatName: name, messages: msgs,
                    failed: DemoData.failedIDs(for: id))
            }
            // Message-hit jump (om-ja-search): demo threads load
            // synchronously, so the seek lands in-memory (no paging).
            if let seek { conv.seek(messageID: seek) }
            // Shot hook: arm the forward sheet on a mid-thread bubble
            // (Tom's mocks note in the default thread), once.
            if showForward, forwardMessage == nil {
                let pick = msgs.count > 1 ? msgs[1] : msgs.first
                if let pick { forwardMessage = pick }
            }
            // Shot hook: arm the reply chip on Tom's question (or the
            // first bubble when another chat was forced via --chat).
            if showReply {
                let target = msgs.first(where: { $0.id == "rep-2" }) ?? msgs.first
                if let target { conv.beginReply(to: target) }
            }
            // Shot hook: seed two pins on the 1:1 thread (the strip
            // shot) or the showcase thread (the hero shot).
            if showPins || (showShowcase && id == DemoData.showcaseID) {
                for m in msgs.prefix(2) {
                    pinnedMessages.pin(chatID: id, message: m)
                }
            }
            notes.showDemo()
            shared.showDemo(chatID: id, files: DemoData.sharedFiles(for: id))
        } else {
            conv.open(chatID: id, chatName: chatName, seekMessageID: seek)
            // Notes scope: channels read the team (M365 group) notebook;
            // plain chats read the user's own OneNote (no shared notebook).
            notes.open(groupID: teamID(forChannel: id))
            // om-fix-tabs: prefetch Shared on open (cached rows make the
            // tab switch instant); the store skips when already current.
            if shared.chatID != id {
                shared.open(chatID: id)
            }
            // om-receipts: peer positions for Seen state (no list refresh).
            receipts.refresh(threadID: id)
        }
        // d2-send: opening a chat delivers its past-due queue items into
        // it (own-bubbles); claim-then-send keeps this idempotent with
        // the tick.
        fireScheduled()
    }

    /// Team id owning a channel id, or nil for plain chats/unknown ids.
    func teamID(forChannel channelID: String) -> String? {
        teams.teams.first(where: { team in
            team.channels.contains(where: { $0.id == channelID })
        })?.teamId
    }

    /// Shot hook: stretch a demo thread past the catch-up threshold by
    /// cycling its own messages (ids stay unique).
    private static func longThread(from base: [ChatMessage]) -> [ChatMessage] {
        guard !base.isEmpty else { return base }
        var out = base
        var n = 0
        while out.count < CatchUp.threshold + 4 {
            let m = base[n % base.count]
            out.append(ChatMessage(
                id: "catchup-fill-\(n)", sender: m.sender,
                timestamp: m.timestamp, content: m.content, isOwn: m.isOwn))
            n += 1
        }
        return out
    }

    /// Seeded fenced-code bubbles for the --show-code shot (top10-code):
    /// a received python block + a sent swift block, stamped with the
    /// thread tail so they land in the tail day section.
    private static func codeShotMessages(stamp: String) -> [ChatMessage] {
        [
            ChatMessage(
                id: "shot-code-1", sender: "Tom Becker", timestamp: stamp,
                content: "Repro from the traceback:\n```python\ndef retry(fn):\n    for i in range(3):\n        try:\n            return fn()\n        except IOError:  # transient\n            continue\n```"),
            ChatMessage(
                id: "shot-code-2", sender: "Me", timestamp: stamp,
                content: "Shipping the fix:\n```swift\nfunc greet(name: String) -> String {\n    // indent kept: 4sp\n    let line = \"hi \\(name)\"\n    return line\n}\n```",
                isOwn: true),
        ]
    }

    /// Seeded saves for the --show-saved shot (offline, throwaway
    /// defaults): a 1:1, a group, and a channel save, newest-last here
    /// (adopt sorts newest-first).
    static let savedShotSeeds: [SavedMessage] = [
        SavedMessage(
            chatID: DemoData.avaID, messageID: "ava-1",
            sender: "Ava Lindqvist",
            preview: "Morning! Can you review the empty-states mock?",
            content: "Morning! Can you review the empty-states mock?",
            timestamp: "2026-09-22T08:41:02Z", savedAt: 1_781_234_500),
        SavedMessage(
            chatID: DemoData.standupID, messageID: "standup-2",
            sender: "Liam Hartley",
            preview: "Standup moved to ten, heads-up for the team.",
            content: "Standup moved to ten, heads-up for the team.",
            timestamp: "2026-09-23T09:02:11Z", savedAt: 1_781_234_560),
        SavedMessage(
            chatID: DemoData.longChannelID, teamID: "demo-team",
            channelID: DemoData.longChannelID, messageID: "chan-7",
            sender: "Sofia Marchetti",
            preview: "Release notes draft is ready for review.",
            content: "Release notes draft is ready for review.",
            timestamp: "2026-09-24T15:20:44Z", savedAt: 1_781_234_620),
    ]

    /// Canned bullets for the --show-action-items shot (thread
    /// extraction: owners, no cue timestamps).
    static let actionItemsThreadStub = """
    - Own code blocks for the richness pass — Tom Becker
    - Double-check the edited marker on the demo bubble — Megan Harper
    - Take screenshots for the review deck — Unassigned
    """

    /// Canned bullets for the --show-transcripts-actions shot (turns
    /// extraction: owners + source cue timestamps).
    static let actionItemsTranscriptStub = """
    - Ship the chat window picker — Megan Harper [0:43]
    - Update the empty-states mock — Ava Lindqvist [0:49]
    - Take screenshots for the review deck — Unassigned [1:02:03]
    """

    /// Canned summary for the --show-catchup shot (offline, no model).
    static let catchUpDemoSummary = """
    TL;DR
    Design sync covered the chat window mocks and the send flow; edits stay in place.

    Key points
    - Tom shipped new chat window mocks with bubbles and timestamps.
    - Megan asked that edited messages update in place, not re-sort.
    - Send flow is an optimistic bubble first, then core confirms.

    Action items
    - Tom: own code blocks for the richness pass.
    - Me: double-check the edited marker on the demo bubble.
    - Unassigned: take screenshots for the review deck.
    """

    /// One live event: count it, refresh the list row (all chats),
    /// route the bubble to the open chat only. 1:1 chats also learn
    /// the mate's sender MRI for live presence dots (own messages
    /// and group chats skipped — same sender==name identity rule as
    /// ConversationStore).
    /// One typing event: count it, refresh that sender's per-thread
    /// timeout. Never touches the chat list (no refresh — the timeline
    /// row is the only surface); own typing echoes are skipped.
    private func handleTyping(_ ev: TypingEvent) {
        feedTyping += 1
        if ev.sender != conv.ownDisplayName {
            typing.ingest(ev)
        }
    }

    /// One roster snapshot: count it, upsert the row in place. Never
    /// touches the chat list (no refresh — the roster is the only
    /// surface); own rows are kept (self is a participant too).
    private func handleRoster(_ ev: MeetingRosterEvent) {
        feedRoster += 1
        meeting.ingest(ev)
    }

    /// Call events land in the call slot; a remote end also closes the
    /// meeting (the thread stays persisted, roster speaking clears).
    private func handleCall(_ ev: CallEvent) {
        call.ingest(ev)
        if ev.kind == "end" || ev.kind == "rejected" {
            meetingChat.endMeeting()
            meeting.noteMeetingEnded()
        }
    }

    // MARK: - Offline search index (gap-g6g7)

    /// Index one history batch (conv.onHistory: open/seek/loadMore/demo).
    private func indexHistory(chatID: String, messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        localSearch.index(chatID: chatID, messages: messages)
        searchIndexDocs = localSearch.docCount
        searchIndexError = nil
        scheduleSearchIndexSave()
    }

    /// Drop one doc after a confirmed delete (conv.onDelete).
    private func dropIndexed(chatID: String, messageID: String) {
        localSearch.remove(chatID: chatID, messageID: messageID)
        searchIndexDocs = localSearch.docCount
        scheduleSearchIndexSave()
    }

    /// Debounced OMIX persist (2s quiet window; cancels superseded).
    private func scheduleSearchIndexSave() {
        searchIndexSaveTask?.cancel()
        let accountID = searchIndexAccountID
        searchIndexSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                try self?.localSearch.saveDefault(for: accountID)
            } catch {
                self?.searchIndexError = "index save: \(error)"
            }
        }
    }

    /// Flush the old account's index, then point the store at the new
    /// account's file (empty when the account never indexed).
    private func switchSearchIndex(to accountID: String) {
        searchIndexSaveTask?.cancel()
        searchIndexSaveTask = nil
        do {
            try localSearch.saveDefault(for: searchIndexAccountID)
        } catch {
            searchIndexError = "index save: \(error)"
        }
        searchIndexAccountID = accountID
        localSearch.removeAll()
        do {
            try localSearch.loadDefault(for: accountID)
            searchIndexError = nil
        } catch {
            searchIndexError = "index load: \(error)"
        }
        searchIndexDocs = localSearch.docCount
    }

    private func handleRealtime(_ msg: RealtimeMessage) {
        feedEvents += 1
        refreshFeedStatus()
        // om-leave-block: blocked senders skip everything (list, typing,
        // unread, mentions, banners) — counted as a skip in Diagnostics.
        // Unknown threads default to 1:1, so a new thread from a blocked
        // mate still matches by name.
        let threadGroup = chats.chat(id: msg.chatID)?.is_group ?? false
        if blocked.isBlocked(chatID: msg.chatID, senderName: msg.sender, isGroup: threadGroup) {
            notifSkipped += 1
            notifLastReason = "blocked-user"
            return
        }
        typing.noteMessage(
            chatID: msg.chatID, sender: msg.sender, senderID: msg.senderID)
        chats.ingest(realtime: msg)
        // gap-g6g7: realtime → offline index (edits re-index onto the
        // same doc; reaction-only events carry no text — never index
        // an empty body over real content).
        if !msg.text.isEmpty {
            indexHistory(chatID: msg.chatID, messages: [msg.asChatMessage])
        }
        // om-nc-delivery: the rules decision below owns the single banner
        // (maybeNotify); no second post here — one event, one banner max.
        // om-quiet-hours: snapshot quiet ONCE per event; the banner path
        // below obeys it (banners/sounds drop; unread pauses too —
        // quiet-hours skips never accrue). e2-attention: Focus-quiet
        // folds into the same snapshot (identical semantics, same reason).
        let quiet = localQuietNow
        if let mri = msg.senderID,
           msg.sender != conv.ownDisplayName,
           chats.chat(id: msg.chatID)?.is_group == false
        {
            Task { await presence.refreshChatPeerMri(chatID: msg.chatID, mri: mri) }
        }
        // om-rules + om-notifbadge + om-mention-alerts: ONE rules decision
        // per event (presence-DND, then local quiet, then mute-with-
        // breakthrough) drives the banner (all chats, open one included
        // — TN parity), the unread counts (skips and the open chat never
        // accrue), and the alert stats. Quiet ALSO gates the banner path
        // below (defense in depth + suppressed counting).
        let chatName = chats.chat(id: msg.chatID)?.name ?? ""
        let decision = rulesDecision(for: msg, chatName: chatName)
        noteAlertStats(decision: decision)
        switch decision {
        case .notify(let reason):
            notifPosted += 1
            notifLastReason = reason
        case .skip(let reason):
            notifSkipped += 1
            notifLastReason = reason
        }
        // e1-popout: popped chats count as open (no unread/mention
        // accrual while visible); banners below still fire for them.
        let visible = popouts.visibleChatIDs(open: openChatID)
        unread.ingest(
            decision: decision, chatID: msg.chatID, openChatID: openChatID,
            visibleChatIDs: visible)
        mentions.ingest(
            realtime: msg, ownName: conv.ownDisplayName,
            ownerMRI: resolvedOwnerMRI, openChatID: openChatID,
            visibleChatIDs: visible)
        // e1-activity: mentions/replies land in the feed (same gates as
        // the MentionStore flags, plus channel blasts + quote replies).
        activity.ingest(
            realtime: msg, ownName: conv.ownDisplayName,
            ownerMRI: resolvedOwnerMRI, openChatID: openChatID,
            chatName: chatName, visibleChatIDs: visible)
        // e1-activity: reaction totals ride in for the count-delta
        // heuristic. Ownership resolves only for loaded open-chat
        // bubbles (unknown ownership baselines without emitting); the
        // pre-ingest bubble seeds the baseline so the delta is exact.
        if let r = msg.reactions {
            let targetID = msg.isEdit ? (msg.editedID ?? msg.msgId) : msg.msgId
            var own: Bool?
            if msg.isFor(chatID: openChatID),
               let bubble = conv.messages.first(where: { $0.id == targetID })
            {
                activity.seedBaseline(
                    chatID: msg.chatID, messageID: targetID,
                    total: bubble.reactions.reduce(0) { $0 + $1.count })
                own = bubble.isOwn
            }
            activity.noteReaction(
                chatID: msg.chatID, messageID: targetID, reactions: r,
                chatName: chatName, isOwnMessage: own)
        }
        if quiet {
            noteSuppressedIfWarranted(msg, chatName: chatName, decision: decision)
        } else {
            maybeNotify(
                msg, chatName: chatName, decision: decision,
                mutedChatIDs: rules.config.mutedChatIDs)
        }
        // om-meet-chat: meeting-thread events adopt the meeting panel
        // (any meeting thread, not just the open chat). The panel owns
        // its thread; the chat list is untouched by this path.
        meetingChat.ingestIfMeeting(realtime: msg)
        // e1-popout: the main timeline takes its chat; every popped chat
        // takes its own — the main selection never moves for pop-out
        // traffic, and popped threads refresh Seen like open ones.
        let seenWorthy = !msg.isEdit && !msg.text.isEmpty
        if msg.isFor(chatID: openChatID) {
            conv.ingest(realtime: msg)
            // om-receipts: a peer reply implies they read through our tail;
            // refresh Seen state (no list refresh — receipts only).
            if seenWorthy {
                receipts.refresh(threadID: msg.chatID)
            }
        }
        if popouts.ingest(realtime: msg), seenWorthy {
            receipts.refresh(threadID: msg.chatID)
        }
        // gap-g2 fan-out (live leg): a window open on the event's
        // account takes it too (live events stamp nil = active; the
        // registry resolves that). Same decision — never re-decided.
        _ = accountWindows.ingest(
            msg, decision: decision, activeID: accounts.activeID)
    }

    /// Owner MRI for live-event matching: configured value wins, else
    /// the Graph-learned one (nil until it lands — the display-name
    /// backup covers the gap). Shared by the rules decision and the
    /// mention tracker so both gates see the same identity.
    private var resolvedOwnerMRI: String? {
        rules.config.owner.mri.isEmpty ? ownerMRI : rules.config.owner.mri
    }

    /// Local quiet snapshot (e2-attention): schedule/DND-quiet OR
    /// Focus-quiet — identical semantics downstream (same snapshot fed
    /// to the banner gate and the rules quiet gate, same reason).
    private var localQuietNow: Bool {
        quietHours.isQuietNow || focusSync.quietNow
    }

    /// One rules decision for a live event (owns the meeting-start
    /// window claim). Owner identity prefers configured/learned MRI with
    /// a live display-name backup. DND reads the own Teams presence;
    /// quiet reads the local snapshot (schedule, manual DND, or Focus —
    /// all suppress mentions too).
    private func rulesDecision(for msg: RealtimeMessage, chatName: String) -> ChatFilter.Decision {
        var cfg = rules.config
        if let own = conv.ownDisplayName, !own.isEmpty { cfg.owner.displayName = own }
        return ChatFilter.decide(
            message: msg, chatDisplayName: chatName, ownerMRI: resolvedOwnerMRI,
            rules: cfg, meetingDedup: &meetingDedup, now: Date(),
            dndActive: MentionAlert.isDND(ownAvailability: presence.own?.availability),
            quietActive: localQuietNow,
            snoozedChatIDs: snooze.activeIDs())
    }

    /// Mention-alert counters (Diagnostics only): breakthroughs through
    /// mute, DND suppressions, quiet-hours suppressions.
    private func noteAlertStats(decision: ChatFilter.Decision) {
        switch decision {
        case .notify(let reason) where reason == MentionAlert.breakthroughReason:
            mentionBreakthroughs += 1
        case .skip(let reason) where reason == MentionAlert.dndReason:
            mentionDNDSuppressions += 1
        case .skip(let reason) where reason == MentionAlert.quietReason:
            mentionQuietSuppressions += 1
        default:
            break
        }
    }

    /// Quiet-held event (om-quiet-hours): count ONE suppression when a
    /// banner would otherwise have posted — rules .notify and/or the
    /// legacy non-open-chat path. Rules already decided above; this only
    /// records that quiet held the banner back (counted once per event).
    private func noteSuppressedIfWarranted(_ msg: RealtimeMessage, chatName: String, decision: ChatFilter.Decision) {
        let rulesNotified: Bool
        if case .notify = decision {
            rulesNotified = true
        } else {
            rulesNotified = false
        }
        // Same pure gate the legacy banner path uses ("" reads as unnamed,
        // exactly like the nil the Task passes when the chat is unknown).
        let legacyWouldPost = MessageNotifications.makeNotification(
            for: msg, chatName: chatName,
            openChatID: openChatID, ownDisplayName: conv.ownDisplayName) != nil
        if QuietHoursGate.countsSuppression(
            quiet: true, bannersEnabled: notifs.enabled,
            rulesNotified: rulesNotified, legacyWouldPost: legacyWouldPost)
        {
            quietHours.noteSuppressed()
        }
    }

    /// Rules-based banner for one live event (om-nc-delivery: the rules
    /// decision maps to a banner via NcDelivery — skips suppress, meeting
    /// signals synthesize their body, locked screens redact). Posts through
    /// Notifier (thread-grouped, inline Reply). Respects the Settings
    /// banner toggle (om-settings-trim) so OFF is really off, the per-chat
    /// mute set (defense in depth — the rules engine already skips muted
    /// chats), the snooze set (same), and the preview/sound toggles via
    /// the one banner home.
    /// Quiet hours/DND gate the call (never reach here while quiet).
    /// Breakthrough mentions and keyword hits post elevated (OM_MENTION
    /// style + subtitle).
    /// gap-g1: background calls pass the owning account (banner names
    /// it, userInfo routes to it) plus the snapshot owner identity for
    /// the breakthrough subtitle. Live calls omit all four (nil = active
    /// account, live conv identity — unchanged behavior).
    private func maybeNotify(
        _ msg: RealtimeMessage, chatName: String,
        decision: ChatFilter.Decision, mutedChatIDs: Set<String>,
        accountID: String? = nil, accountName: String? = nil,
        ownerDisplayName: String? = nil, ownerMRI: String? = nil
    ) {
        guard notifs.enabled else { return }
        guard !mutedChatIDs.contains(msg.chatID) else { return }
        guard !snooze.isSnoozed(chatID: msg.chatID) else { return }
        guard case .notify(let reason) = decision else { return }
        // d2-alerts: keyword hits elevate like breakthrough mentions
        // (OM_MENTION style family, "Keyword alert" subtitle).
        let keyword = KeywordAlert.elevation(forReason: reason)
        let breakthrough = reason == MentionAlert.breakthroughReason || keyword.isElevated
        var subtitle: String? = keyword.subtitle
        if reason == MentionAlert.breakthroughReason {
            // Same identity the decision used (live name wins, per-chat
            // gates resolve identically — pure, no extra window claim).
            // Background calls pass the snapshot identity instead.
            var cfg = rules.config
            if let own = (ownerDisplayName ?? conv.ownDisplayName), !own.isEmpty {
                cfg.owner.displayName = own
            }
            let eff = cfg.effective(forChat: chatName)
            let mined = msg.mentions
            let ownerHit = Mentions.mentionsOwner(
                mined, ownerMRI: ownerMRI ?? resolvedOwnerMRI,
                ownerDisplayName: eff.ownerDisplayName,
                matchByName: eff.matchByDisplayName)
            subtitle = MentionAlert.subtitle(
                ownerMention: ownerHit,
                channelMention: Mentions.mentionsChannelOrEveryone(mined))
        }
        guard let banner = NcDelivery.makeBanner(
            for: msg, chatName: chatName,
            decision: decision, screenLocked: NcDelivery.isScreenLocked(),
            showPreview: notifs.showPreview, sound: notifs.sound,
            isMention: breakthrough, subtitle: subtitle,
            accountName: accountName)
        else { return }
        Notifier.shared.post(
            title: banner.title, body: banner.body,
            id: banner.id.isEmpty ? nil : banner.id, chatID: banner.chatID,
            sound: banner.sound, isMention: banner.isMention, subtitle: banner.subtitle,
            accountID: accountID)
    }

    /// Wire the notifier: categories + auth for rules-posted banners.
    /// The shared delegate (notifs.attach, installed after this) owns
    /// response routing via .omNotifOpenChat/.omNotifReply; these
    /// closures still carry the real send/jump (and select the
    /// Reply-bearing category) so banners stay actionable if install
    /// order ever flips Notifier's own delegate back on.
    /// Live mode only (demo never starts the feed, so never notifies).
    private func setupNotifier() {
        Notifier.shared.setup()
        Notifier.shared.onOpenChat = { [weak self] chatID, accountID in
            guard let strongSelf = self else { return }
            await MainActor.run {
                strongSelf.openFromNotification(chatID: chatID, accountID: accountID)
            }
        }
        // gap-g1: a foreign-account reply switches first (on-main),
        // then sends on the delegate queue (blocking, ex-main) — the
        // profile flip is synchronous, so the send lands on the right
        // account. A failed switch fails the reply (loud system note),
        // never sends from the wrong account.
        Notifier.shared.onReply = { [weak self] chatID, text, accountID in
            let ready = await MainActor.run { [weak self] in
                self?.prepareReplyAccount(accountID) ?? true
            }
            guard ready else {
                return .failure(CoreCallError.failed(
                    "couldn't switch to the message's account"))
            }
            do {
                _ = try RustCore.send(chatID: chatID, text: text)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        // gap-g3: Notifier-delegate fallback for call banners (same
        // accept/end as the shared-delegate notes above; only fires if
        // install order ever flips Notifier's own delegate back on).
        Notifier.shared.onAcceptCall = { [weak self] _ in
            await MainActor.run { self?.call.accept() }
        }
        Notifier.shared.onDeclineCall = { [weak self] _ in
            await MainActor.run { self?.call.end() }
        }
        Task { _ = await Notifier.shared.requestAuthorization() }
    }

    /// Learn the owner MRI (`8:orgid:{oid}`) from Graph /me for
    /// MRI-preferred own/mention matching. Off-main (first call may hit
    /// network); the display-name backup covers messages until it lands.
    private func resolveOwnerMRI() {
        Task.detached { [weak self] in
            guard let me = try? RustCore.whoami(), !me.id.isEmpty else { return }
            let mri = "8:orgid:\(me.id)"
            guard let strongSelf = self else { return }
            await MainActor.run { strongSelf.ownerMRI = mri }
        }
    }

    /// Banner click (gap-g1): a foreign-account banner switches to
    /// its account first, then jumps (jump falls back to direct open
    /// while the post-switch list loads). Unknown foreign accounts are
    /// stale banners — dropped, never opened in the wrong account.
    private func openFromNotification(chatID id: String, accountID: String?) {
        if let acct = accountID, acct != accounts.activeID {
            guard !isDemo, accounts.accounts.contains(where: { $0.id == acct }) else { return }
            switchAccount(to: acct)
        }
        let name = chats.chat(id: id)?.name ?? "Conversation"
        jump(chatID: id, chatName: name)
    }

    /// False unless a reply may send on `accountID`: foreign accounts
    /// switch first (sync profile flip); demo, unknown accounts, and
    /// failed flips refuse (the caller fails loud, never cross-sends).
    private func prepareReplyAccount(_ accountID: String?) -> Bool {
        guard let acct = accountID, acct != accounts.activeID else { return true }
        guard !isDemo, accounts.accounts.contains(where: { $0.id == acct }) else { return false }
        return accounts.switchTo(acct)
    }

    /// Inline reply from a notification: optimistic bubble when the chat
    /// is open, direct core send otherwise (no chat switch). gap-g1: a
    /// foreign-account reply switches to its account first, then sends
    /// (the flip is synchronous, so the detached send lands right); a
    /// refused switch posts a loud failure instead of cross-sending.
    private func sendFromNotification(chatID id: String, text: String, accountID: String? = nil) {
        if let acct = accountID, acct != accounts.activeID {
            guard prepareReplyAccount(acct) else {
                Notifier.shared.postSystem(
                    title: "OstMac: reply failed",
                    body: "Reply failed: couldn't switch to the message's account.")
                return
            }
            Task.detached {
                _ = try? RustCore.send(chatID: id, text: text)
            }
            return
        }
        if openChatID == id {
            conv.send(text: text)
            return
        }
        Task.detached {
            _ = try? RustCore.send(chatID: id, text: text)
        }
    }

    /// Push had a gap: re-fetch the open chat plus the list.
    private func handleResync() {
        feedResyncs += 1
        refreshFeedStatus()
        if let id = openChatID, !isDemo {
            conv.open(chatID: id)
        }
        chats.refresh()
    }

    // MARK: - Background accounts (gap-g1)

    /// Sweep cadence over inactive accounts (accept: banner within 60s
    /// of an arrival — one interval covers worst-case skew).
    private static let bgPollInterval: TimeInterval = 30

    /// Start the background sweep (live only, once): an immediate seed
    /// sweep plus the 30s timer. Ungated — unlike the 2s tick it fires
    /// while minimized, which is the whole point.
    private func startBackgroundPoll() {
        guard !isDemo, bgTimer == nil else { return }
        bgTimer = Timer.scheduledTimer(
            withTimeInterval: Self.bgPollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepBackgroundAccounts() }
        }
        sweepBackgroundAccounts()
    }

    /// One sweep: snapshot the account list on-main, diff off-main
    /// (blocking network), handle arrivals back on-main. Skipped while
    /// a single account is active (nothing to sweep).
    private func sweepBackgroundAccounts() {
        guard !isDemo else { return }
        let snapshot = accounts.accounts
        let active = accounts.activeID
        guard snapshot.contains(where: { $0.id != active }) else { return }
        let poller = bgPoller
        Task.detached { [weak self] in
            let events = poller.pollOnce(accounts: snapshot, activeID: active)
            guard !events.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.handleBackgroundEvents(events)
            }
        }
    }

    private func handleBackgroundEvents(_ events: [BackgroundChatEvent]) {
        for ev in events {
            handleBackgroundEvent(ev)
        }
    }

    /// One inactive-account arrival: the same rules decision as the live
    /// path, but against that account's rules snapshot (its owner
    /// identity, never the active account's). Notifies accrue into the
    /// roll-up stash + post an account-naming banner (counted in the
    /// shared notifPosted/notifSkipped + alert stats); skips stay
    /// silent. Never touches the active account's list, timeline,
    /// receipts, presence, or mentions — those rebind on switch.
    private func handleBackgroundEvent(_ ev: BackgroundChatEvent) {
        bgEvents += 1
        // The account may have been removed mid-sweep — drop the event.
        guard let account = accounts.accounts.first(where: { $0.id == ev.accountID }) else { return }
        let msg = ev.asRealtimeMessage
        // Blocked senders skip everything (device-global list, same
        // gate as the live path; groupness rides the polled row).
        if blocked.isBlocked(chatID: msg.chatID, senderName: msg.sender, isGroup: ev.isGroup) {
            notifSkipped += 1
            notifLastReason = "blocked-user"
            return
        }
        let cfg = BackgroundRules.snapshot(base: rules.config, account: account)
        let decision = ChatFilter.decide(
            message: msg, chatDisplayName: ev.chatName,
            ownerMRI: BackgroundRules.ownerMRI(account: account),
            rules: cfg, meetingDedup: &meetingDedup, now: Date(),
            // Own Teams presence belongs to the ACTIVE account — not a
            // signal for this one. Local quiet (schedule/Focus) is
            // device-global and applies; snoozes key by chat id.
            dndActive: false,
            quietActive: localQuietNow,
            snoozedChatIDs: snooze.activeIDs())
        noteAlertStats(decision: decision)
        switch decision {
        case .notify(let reason):
            notifPosted += 1
            notifLastReason = reason
        case .skip(let reason):
            notifSkipped += 1
            notifLastReason = reason
        }
        guard case .notify = decision else { return }
        // gap-g2 fan-out (background leg): a window open on this
        // account owns the event (list bump + open-conv bubble + its
        // own unread) instead of the switch roll-up; the banner below
        // still posts (the window may be behind).
        if accountWindows.isOpen(accountID: ev.accountID) {
            _ = accountWindows.ingest(
                msg, decision: decision, activeID: accounts.activeID)
        } else {
            bgRollup.note(accountID: ev.accountID, chatID: ev.chatID)
        }
        if localQuietNow {
            noteSuppressedIfWarranted(msg, chatName: ev.chatName, decision: decision)
        } else {
            maybeNotify(
                msg, chatName: ev.chatName, decision: decision,
                mutedChatIDs: rules.config.mutedChatIDs,
                accountID: ev.accountID, accountName: ev.accountName,
                ownerDisplayName: account.displayName,
                ownerMRI: BackgroundRules.ownerMRI(account: account))
        }
    }

    /// 2s status tick, gated on visible surfaces: hidden/miniaturized
    /// windows read nothing, so skip the whole poll (feed reads, quiet
    /// sweep, slot re-read). The next visible tick refreshes (≤2s stale,
    /// invisible anyway). Event paths still call refreshFeedStatus
    /// directly (never gated).
    private func tick() {
        guard Self.surfacesVisible() else { return }
        refreshFeedStatus()
    }

    /// Any app window on screen (not hidden or miniaturized).
    static func surfacesVisible() -> Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    private func refreshFeedStatus() {
        // Assign-on-change only: @Published emits per set, so an idle
        // tick must not publish (else the root re-evals every 2s).
        let freshState = feed.currentState
        if freshState != feedState { feedState = freshState }
        if feed.pollCount != feedPolls { feedPolls = feed.pollCount }
        if feed.lastError != feedError { feedError = feed.lastError }
        quietHours.refresh() // om-quiet-hours: sweep expired DND (2s tick)
        focusSync.refresh() // e2-attention: re-poll Focus (assign-on-change)
        // e2-attention: scheduled presence sets (transitions only;
        // signed-in live only — demo and the offline attention shot
        // never touch core). top10-presence: the truth tick always runs
        // (sweep + reconcile + rows) but writes only when live.
        if !CommandLine.arguments.contains("--show-settings-attention") {
            presenceTruth.liveWrites = signedIn == true && !isDemo
            presenceTruth.tick()
            if signedIn == true, !isDemo {
                presenceSchedule.tick()
            }
        }
        snooze.refresh() // d2-send: sweep expired snoozes (2s tick)
        fireScheduled() // d2-send: post due queue items (idle = no-op)
        if !isDemo { call.refresh() } // re-read slot (place/accept landed?)
    }

    /// Post every due scheduled item, oldest first. Claim-then-send lives
    /// in the store (each item fires at most once); delivery reuses the
    /// open chat's send path when it matches (optimistic own-bubble) and
    /// posts directly via core otherwise. Demo mode claims the open
    /// chat's items only (non-open items wait for their chat — offline,
    /// never touches core). Neither path touches the chat list
    /// (zero-refresh).
    private func fireScheduled(now: Date = Date()) {
        let open = openChatID
        let due: [ScheduledItem]
        if isDemo {
            due = scheduled.claimDue(now: now) { $0.chatID == open }
        } else {
            due = scheduled.claimDue(now: now)
        }
        for item in due {
            deliverScheduled(item)
        }
    }

    private func deliverScheduled(_ item: ScheduledItem) {
        if item.chatID == openChatID {
            conv.send(text: item.text)
            return
        }
        if isDemo { return }
        let id = item.chatID, body = item.text
        Task.detached {
            try? RustCore.send(chatID: id, text: body)
        }
    }

    /// Seed the Shifts team picker from the loaded teams and open the
    /// selected (or first) team (B1 merge; demo + live share the path).
    private func seedShifts() {
        let items = teams.teams.map { ShiftTeam(id: $0.teamId, name: $0.name) }
        guard !items.isEmpty else { return }
        shifts.setTeams(items)
        shifts.open(teamID: shifts.selectedTeamID ?? items[0].id)
    }

    /// Demo week-grid meetings dated inside the current week (B1 merge).
    /// Nonisolated: runs inside the store's off-main fetch closure.
    private nonisolated static func calWeekDemoResponse() -> CalWeekResponse {
        let monday = CalWeek.startOfWeek(containing: Date())
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func at(dayOffset: Int, hour: Int, minute: Int) -> String {
            let base = cal.date(byAdding: .day, value: dayOffset, to: monday) ?? monday
            let parts = cal.dateComponents([.year, .month, .day], from: base)
            let date = cal.date(from: DateComponents(
                year: parts.year, month: parts.month, day: parts.day,
                hour: hour, minute: minute)) ?? base
            return fmt.string(from: date)
        }
        return CalWeekResponse(
            ok: true,
            weekStart: Int64(monday.timeIntervalSince1970), days: 7,
            meetings: [
                MeetingItem(
                    meetingId: "demo-cal-standup", subject: "Engineering standup",
                    start: at(dayOffset: 0, hour: 9, minute: 0),
                    end: at(dayOffset: 0, hour: 9, minute: 15),
                    joinURL: "https://teams.microsoft.com/l/meetup-join/19:demo_standup@thread.v2/0",
                    organizer: "Doe, Jane", isOnline: true),
                MeetingItem(
                    meetingId: "demo-cal-crit", subject: "Design crit (Room 3B)",
                    start: at(dayOffset: 1, hour: 14, minute: 0),
                    end: at(dayOffset: 1, hour: 15, minute: 0),
                    organizer: "Lee, Sam"),
            ])
    }

    /// Demo Shifts week dated inside the current week (B1 merge; shift
    /// labels only, no person names). Nonisolated: runs inside the
    /// store's off-main fetch closure (Monday calc mirrors
    /// `ShiftsStore.currentWeekStart`, which is MainActor-bound).
    private nonisolated static func shiftsDemoResponse(teamID: String) -> ShiftWeekResponse {
        var mcal = Calendar.current
        mcal.firstWeekday = 2 // Monday
        let comps = mcal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let monday = mcal.date(from: comps) ?? mcal.startOfDay(for: Date())
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func at(dayOffset: Int, hour: Int, minute: Int = 0) -> String {
            let base = cal.date(byAdding: .day, value: dayOffset, to: monday) ?? monday
            let parts = cal.dateComponents([.year, .month, .day], from: base)
            let date = cal.date(from: DateComponents(
                year: parts.year, month: parts.month, day: parts.day,
                hour: hour, minute: minute)) ?? base
            return fmt.string(from: date)
        }
        return ShiftWeekResponse(
            ok: true, team_id: teamID,
            schedule: ShiftSchedule(enabled: true, timeZone: TimeZone.current.identifier),
            shifts: [
                ShiftItem(
                    id: "demo-shift-morning", userId: "u1", displayName: "Morning",
                    start: at(dayOffset: 0, hour: 9), end: at(dayOffset: 0, hour: 17),
                    theme: "blue"),
                ShiftItem(
                    id: "demo-shift-evening", userId: "u2", displayName: "Evening",
                    start: at(dayOffset: 1, hour: 17), end: at(dayOffset: 1, hour: 23),
                    isDraft: true),
            ],
            timesOff: [
                TimeOffItem(
                    id: "demo-off-1", userId: "u1", reasonId: "r1",
                    start: at(dayOffset: 2, hour: 0), end: at(dayOffset: 3, hour: 0)),
            ],
            reasons: [
                TimeOffReason(id: "r1", name: "Vacation", code: "V"),
                TimeOffReason(id: "r2", name: "Sick"),
            ])
    }

    /// Demo sibling-recording lookup: demo transcript stems match the
    /// demo recording stems (`Title with Name` ↔ `Title with Name.mp4`).
    private static func demoRecordingLookup() -> TranscriptsViewModel.RecordingLookup {
        let byStem = Dictionary(
            uniqueKeysWithValues: RecordingsDemo.response().recordings.map {
                (TranscriptItem.stem(of: $0.name), $0)
            })
        return { byStem[$0] }
    }

    /// Gate transition (fired from the $state sink for every auth
    /// change, whichever surface drove it): signed in → open deferred
    /// content (or reload the list + restart the feed when already
    /// open); signed out / expired / failed → park the feed and close
    /// the gate (fail closed; stale rows stay until the next sign-in).
    func authChanged(_ s: AuthState) {
        switch s {
        case .signedIn:
            signedIn = true
            if accounts.accounts.isEmpty, !isDemo {
                Task { await adoptLegacyAccount() }
            }
            if contentOpened {
                if switchingAccount {
                    // d1-accounts: post-switch reload without spinners.
                    switchingAccount = false
                    quietRefreshAfterSwitch()
                    refreshFeedStatus()
                    return
                }
                chats.refresh()
                teams.refresh()
                reminders.refresh()
                planner.refresh()
                recordings.refresh()
                transcripts.refresh()
                meetings.refresh()
                calWeek.refresh()
                if shifts.selectedTeamID == nil {
                    seedShifts()
                } else {
                    shifts.refresh()
                }
                if !isDemo {
                    feed.start()
                    presence.refreshOwnSoon()
                }
            } else {
                Task { await openContentIfAllowed() }
            }
            refreshFeedStatus()
        case .signedOut, .signingOut, .expired, .refreshFailed, .error:
            signedIn = false
            switchingAccount = false
            feed.stop()
            presence.clear()
            presenceSchedule.clearApplied() // e2-attention: drop applied state
            presenceTruth.clearSession() // top10-presence: drop lock/log/devices
            typing.clear()
            meeting.clear()
            meetingChat.clear()
            unread.markAllRead() // om-notifbadge: counts clear on sign-out
            mentions.markAllRead() // om-mention-alerts: flags + dock clear on sign-out
            receipts.clear() // om-receipts: positions clear on sign-out
            ghost.clear() // f1-ghost: counters clear, toggles persist
            refreshFeedStatus()
        default:
            break
        }
    }
}

/// Pop-out chat window (e1-popout): a full ConversationView on the
/// registry's per-chat store. Own Shared/Notes tab stores (the main
/// window's single-chat tabs must not flip); presence/call/typing/
/// receipts/pins/scheduled are chat-keyed shares. Close drops the
/// visible flag only — the store + draft stay cached, so re-pop
/// restores with no reload and no list touch.
struct PopOutRootView: View {
    @ObservedObject var state: AppState
    let chatID: String
    @StateObject private var shared = SharedFilesStore()
    @StateObject private var notes = NotesStore()

    var body: some View {
        DensityHost(density: state.density) {
            ConversationView(
                store: state.popouts.store(for: chatID),
                presence: state.presence,
                call: state.call, shared: shared, notes: notes,
                catchUp: state.catchUp, typing: state.typing,
                receipts: state.receipts,
                pins: state.pinnedMessages,
                scheduled: state.scheduled,
                canned: state.canned,
                isGroup: state.chats.chat(id: chatID)?.is_group ?? true,
                onForward: { state.beginForward($0) },
                initialDraft: state.popouts.draft(for: chatID),
                onDraftChange: { state.popouts.saveDraft($0, for: chatID) })
            .popoutWindowTitle(state.popoutName(for: chatID))
            .onAppear {
                state.openPopout(chatID: chatID)
                if state.isDemo {
                    notes.showDemo()
                    shared.showDemo(
                        chatID: chatID, files: DemoData.sharedFiles(for: chatID))
                } else {
                    notes.open(groupID: state.teamID(forChannel: chatID))
                    shared.open(chatID: chatID)
                }
            }
            .onDisappear { state.popouts.close(chatID: chatID) }
        }
    }
}

/// Side-by-side account window (gap-g2): the graph's chat list plus
/// its conversation, both live-updating off the fan-out. Own
/// Shared/Notes tab stores (un-opened — files/notes stay
/// main-window); presence/call/typing/receipts/scheduled/canned are
/// chat-keyed shares (pop-out precedent). Close drains the graph's
/// unread into the background roll-up and drops the visible flag —
/// the graph stays cached, so re-open restores with no reload.
struct AccountWindowRootView: View {
    @ObservedObject var state: AppState
    let accountID: String
    @StateObject private var shared = SharedFilesStore()
    @StateObject private var notes = NotesStore()

    var body: some View {
        if let graph = state.accountWindows.graph(for: accountID) {
            AccountWindowContent(
                state: state, graph: graph,
                shared: shared, notes: notes)
        } else {
            // Removed account (the registry evicted the graph).
            VStack(spacing: 8) {
                Text("Account removed")
                    .font(.headline)
                Text("This account was removed. Close this window.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AccountWindowContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var graph: AccountWindowGraph
    @ObservedObject var shared: SharedFilesStore
    @ObservedObject var notes: NotesStore

    var body: some View {
        DensityHost(density: state.density) {
            NavigationSplitView {
                AccountWindowListView(
                    chats: graph.chats, unread: graph.unread)
            } detail: {
                if let openID = graph.openChatID {
                    ConversationView(
                        store: graph.conv,
                        presence: state.presence,
                        call: state.call, shared: shared, notes: notes,
                        catchUp: state.catchUp, typing: state.typing,
                        receipts: state.receipts,
                        pins: graph.pins,
                        saved: graph.saved,
                        scheduled: state.scheduled,
                        canned: state.canned,
                        isGroup: graph.chats.chat(id: openID)?.is_group ?? true,
                        onForward: { state.beginForward($0) },
                        initialDraft: state.popouts.draft(for: openID),
                        onDraftChange: {
                            state.popouts.saveDraft($0, for: openID)
                        })
                } else {
                    VStack(spacing: 8) {
                        Text("No chat selected")
                            .font(.headline)
                        Text("Pick a chat from the list.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .popoutWindowTitle(graph.account.displayName)
            .onDisappear {
                state.closeAccountWindow(accountID: graph.account.id)
            }
        }
    }
}

/// Minimal window list (gap-g2): rows + unread dots + selection. No
/// leave/block entries (active-profile FFI has no window path), no
/// folders UI (the VM still filters blocked rows).
private struct AccountWindowListView: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore

    var body: some View {
        Group {
            switch chats.state {
            case .loading:
                ProgressView("Loading chats…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                Text("No chats")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Retry") { chats.refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                List(selection: $chats.selectedChatID) {
                    ForEach(chats.chats) { chat in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.name)
                                    .lineLimit(1)
                                if let preview = chat.last_message_preview,
                                   !preview.isEmpty
                                {
                                    Text(preview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            let n = unread.count(for: chat.id)
                            if n > 0 {
                                Text("\(n)")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(Color.accentColor))
                            }
                        }
                        .tag(chat.id)
                    }
                }
            }
        }
        .task {
            // First appear only: the cached graph keeps its rows, so
            // re-open never refetches (close loses no state).
            if chats.state == .loading {
                await chats.load()
            }
        }
    }
}

/// Stale restored pop-out (its value decoded nil): closes itself so no
/// empty "Chat" window lingers.
private struct PopOutEmptyView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task { dismissWindow() }
    }
}

/// Per-window title for value-driven pop-outs (the scene title is static,
/// so each window stamps its own chat name through its own view).
private struct PopoutTitleProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI stamps the static scene title at creation; the async
        // hop lands after it so the chat name wins and sticks. The view
        // is sometimes not yet attached on the first pass — retry until
        // the window exists (bounded, ~6s).
        stamp(view, name: name, tries: 0)
    }

    private func stamp(_ view: NSView, name: String, tries: Int) {
        let hop: DispatchTimeInterval = tries == 0 ? .nanoseconds(0) : .milliseconds(50)
        DispatchQueue.main.asyncAfter(deadline: .now() + hop) { [weak view] in
            guard let view else { return }
            guard let window = view.window else {
                if tries < 120 {
                    self.stamp(view, name: name, tries: tries + 1)
                }
                return
            }
            if window.title != name { window.title = name }
        }
    }
}

private extension View {
    func popoutWindowTitle(_ name: String) -> some View {
        background(PopoutTitleProbe(name: name))
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Shot-hook section (mapping lives on SidebarSection so tests
    /// pin it; AppState inits from the same function).
    static var initialSection: SidebarSection {
        SidebarSection.initialSection(args: CommandLine.arguments)
    }

    var body: some View {
        // Shot hook (f1-actions): the real popover content standalone
        // (same view, same canned store; see the flag comment).
        if CommandLine.arguments.contains("--show-action-items-window") {
            ActionItemsView(
                actions: state.actionItems,
                messages: DemoData.messages(for: DemoData.demoID),
                chatID: DemoData.demoID, autoRun: true)
        } else {
            // Message density (f2-density): one host publishes the
            // mode to sidebar + timeline (instant re-layout, no
            // reload, no scroll calls).
            DensityHost(density: state.density) {
                mainBody
            }
        }
    }

    private var mainBody: some View {
        VStack(spacing: 0) {
            CallBanner(store: state.call) {
                openWindow(id: AppIdentity.callWindowID)
            }
            // top10-presence: undo toast for auto presence changes
            // (renders nothing without a live offer).
            PresenceUndoToast(store: state.presenceTruth)
            if state.isDemo || state.switchingAccount || state.auth.state.allowsContent {
                // R10 shifts-fullwidth: full-window modules take the
                // whole content area outside the rail (chat viewport
                // hidden); anything else keeps the split view. The
                // swap is render-only — stores persist, no refetch.
                if state.sidebarSection.takesFullWindow {
                    shiftsFullBody
                } else {
                    splitBody
                }
            } else {
                // Gate: the full 13-state sign-in where the chats would be.
                AuthView(model: state.auth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DietColor.windowColor)
            }
            DietSeamH()
            StatusBar()
        }
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .showJumpPalette)) { _ in
            state.showJump = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSavedMessages)) { _ in
            state.showSaved = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickComposer)) { _ in
            state.summonComposer()
        }
        // e1-popout shot hook: open the armed pop-out window once the
        // list lands (openWindow lives in the view layer only).
        .onChange(of: state.pendingPopoutID) {
            if let id = state.pendingPopoutID,
               let target = state.popOut(chatID: id)
            {
                state.pendingPopoutID = nil
                openWindow(value: target)
            }
        }
        // gap-g2: open the armed account window (cleared even when the
        // id is stale, so a dead arm never sticks).
        .onChange(of: state.pendingAccountWindowID) {
            if let id = state.pendingAccountWindowID {
                state.pendingAccountWindowID = nil
                if let target = state.openAccountWindow(accountID: id) {
                    openWindow(value: target)
                }
            }
        }
        .sheet(isPresented: $state.showJump) {
            JumpPaletteSheet(
                chats: state.chats, teams: state.teams,
                search: state.messageSearch,
                filePeople: state.filePeople,
                recents: state.searchRecents,
                initialQuery: OstMacAppMain.jumpQuery(args: CommandLine.arguments),
                chatNameFor: { state.chatNameOrNil(for: $0) },
                onPickMessage: { state.jumpToMessage($0) },
                onPickFile: { state.openSearchFile($0) },
                onPickPerson: { state.openSearchPerson($0) }
            ) { id, name in
                state.showJump = false
                state.jump(chatID: id, chatName: name)
            }
        }
        .sheet(isPresented: $state.showSaved) {
            SavedMessagesView(
                store: state.savedMessages,
                live: state.conv.messages,
                showPreview: state.notifs.showPreview,
                chatNameFor: { state.chatNameOrNil(for: $0) },
                onJump: { state.jumpToSaved($0) })
        }
        .sheet(item: $state.forwardMessage) { msg in
            ForwardSheetLive(
                message: msg, chats: state.chats, teams: state.teams,
                initialQuery: OstMacAppMain.jumpQuery(args: CommandLine.arguments)
            ) { id, name in
                state.forwardPicked(destID: id, destName: name)
            }
        }
        .onAppear {
            // Shot hooks: open About/Settings/Auth/A-V windows from launch args.
            if CommandLine.arguments.contains("--show-about") {
                openWindow(id: AppIdentity.aboutWindowID)
            }
            if CommandLine.arguments.contains("--show-av") {
                openWindow(id: AppIdentity.avWindowID)
            }
            if CommandLine.arguments.contains("--show-calls") {
                openWindow(id: AppIdentity.callsWindowID)
            }
            if CommandLine.arguments.contains("--show-meeting") {
                state.meeting.seedDemo()
                state.meetingChat.showDemo(
                    threadID: MeetingDemo.threadID,
                    chatName: MeetingDemo.threadName,
                    messages: MeetingDemo.messages)
                state.meetingChat.adoptIdentity(displayName: "Me")
                openWindow(id: AppIdentity.meetingWindowID)
            }
            if CommandLine.arguments.contains("--show-diagnostics") {
                openWindow(id: AppIdentity.diagWindowID)
            }
            if CommandLine.arguments.contains("--show-meetings") {
                openWindow(id: AppIdentity.meetWindowID)
            }
            if TeamsFrameConfig.shouldOpen(args: CommandLine.arguments) {
                openWindow(id: AppIdentity.teamsFrameWindowID)
            }
            if state.showQuickComposerShot {
                state.summonComposer()
            }
            if CommandLine.arguments.contains("--show-settings")
                || CommandLine.arguments.contains("--show-settings-keywords")
                || CommandLine.arguments.contains("--show-settings-calls")
                || CommandLine.arguments.contains("--show-settings-summaries")
                || CommandLine.arguments.contains("--show-settings-attention")
                || CommandLine.arguments.contains("--show-settings-templates")
                || CommandLine.arguments.contains("--show-settings-chats")
                || CommandLine.arguments.contains("--show-settings-composer") {
                openSettings()
            }
            if OstMacAppMain.authStateName(args: CommandLine.arguments) != nil {
                openWindow(id: AppIdentity.authWindowID)
            }
        }
        .task { await state.startup() }
        .onDisappear { state.shutdown() }
    }

    /// Full-window module body (R10 shifts-fullwidth): the app rail
    /// stays (back-nav target) and the module takes everything else.
    private var shiftsFullBody: some View {
        HStack(spacing: 0) {
            AppNavRail(selection: $state.sidebarSection)
            DietDividerV()
            ShiftsFullView(shifts: state.shifts)
        }
    }

    /// Split body: rail + section browser beside the chat viewport.
    private var splitBody: some View {
        NavigationSplitView {
            SidebarColumn(
                chats: state.chats, teams: state.teams,
                reminders: state.reminders, planner: state.planner,
                recordings: state.recordings,
                transcripts: state.transcripts, shifts: state.shifts,
                contacts: state.contacts,
                presence: state.presence,
                unread: state.unread,
                mentions: state.mentions,
                rules: state.rules,
                snooze: state.snooze,
                activity: state.activity,
                activityPane: $state.activityPane,
                openChatID: state.openChatID,
                section: $state.sidebarSection,
                initialFilter: OstMacAppMain.filterQuery(args: CommandLine.arguments),
                channelCreateOpen: CommandLine.arguments.contains("--show-channel-create"),
                teamCreateOpen: CommandLine.arguments.contains("--show-team-create"),
                initialFolderID: state.folderShotSelection,
                folderManageOpen: CommandLine.arguments.contains("--show-folders-manage"),
                initialEditingRuleID: state.folderShotEditingRuleID,
                onOpenChannel: { id, name in state.openChannel(channelID: id, channelName: name) },
                onPickContact: { state.openSearchPerson($0) },
                onPopOut: { id in
                    if let target = state.popOut(chatID: id) {
                        openWindow(value: target)
                    }
                }
            )
            .navigationSplitViewColumnWidth(
                min: AppNavLayout.sidebarMinWidth, ideal: 300, max: 420)
        } detail: {
            if let pane = state.activityPane {
                activityDetail(pane)
            } else if state.openChatID == nil {
                emptyDetail
            } else {
                ConversationView(
                    store: state.conv, presence: state.presence,
                    call: state.call, shared: state.shared, notes: state.notes,
                    catchUp: state.catchUp, actionItems: state.actionItems,
                    typing: state.typing,
                    receipts: state.receipts,
                    pins: state.pinnedMessages,
                    saved: state.savedMessages,
                    scheduled: state.scheduled,
                    canned: state.canned,
                    isGroup: state.chats.selectedChat?.is_group ?? true,
                    initialTab: CommandLine.arguments.contains("--show-shared") ? 1
                        : (state.showNotes ? 2 : 0),
                    catchUpOpen: state.showCatchUp,
                    onForward: { state.beginForward($0) },
                    editOpen: CommandLine.arguments.contains("--show-edit"),
                    deleteOpen: CommandLine.arguments.contains("--show-delete"),
                    scheduleOpen: CommandLine.arguments.contains("--show-schedule"),
                    scheduledListOpen: CommandLine.arguments.contains("--show-scheduled"),
                    initialDraft: state.popouts.draft(for: state.openChatID ?? ""),
                    onDraftChange: { state.popouts.saveDraft($0, for: state.openChatID ?? "") },
                    savedContext: { state.savedContext(for: $0) })
                    // Per-chat composer (e1-popout): drafts restore
                    // per thread instead of leaking across switches.
                    .id(state.openChatID)
            }
        }
    }

    /// Empty detail keeps the header row aligned with the
    /// conversation header (the rail spans the sidebar full-height).
    private var emptyDetail: some View {
        VStack(spacing: 0) {
            DietHeaderBar { Color.clear }
            DietEmptyState(
                systemImage: "bubble.left.and.bubble.right",
                title: "Select a chat",
                message: "Pick a conversation in the sidebar, or press ⌘K to jump.")
        }
    }

    /// In-window Activity / Mentions list (e1-inwindow): header bar
    /// (same seam row as the conversation header) + the feed/center
    /// list. Row taps jump to the chat (`open` clears the pane).
    private func activityDetail(_ pane: ActivityPane) -> some View {
        VStack(spacing: 0) {
            DietHeaderBar {
                HStack(spacing: DietSpace.sm) {
                    Text(pane.title)
                        .font(DietType.title3)
                        .foregroundStyle(DietColor.textPrimaryColor)
                    Spacer()
                    if pane == .feed {
                        Button("Mark All Reviewed") {
                            state.activity.markAllReviewed()
                        }
                        .disabled(state.activity.visibleItems.isEmpty)
                        .help("Dismiss every activity item")
                    }
                }
            }
            Group {
                switch pane {
                case .feed:
                    ActivityFeedView(
                        store: state.activity,
                        showPreview: state.notifs.showPreview
                    ) { state.jumpToActivity($0) }
                case .center:
                    MentionsCenterView(
                        store: state.activity,
                        showPreview: state.notifs.showPreview
                    ) { state.jumpToActivity($0) }
                }
            }
        }
    }
}

/// Jump sheet, live on the list stores: targets rebuild when
/// chats/teams change mid-palette (was RootView's re-render via the
/// chats forward).
struct JumpPaletteSheet: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var teams: TeamsViewModel
    @ObservedObject var search: MessageSearchStore
    @ObservedObject var filePeople: FilePeopleSearchStore
    @ObservedObject var recents: SearchRecentsStore
    let initialQuery: String
    let chatNameFor: (String) -> String?
    let onPickMessage: (SearchHit) -> Void
    let onPickFile: (SharedFile) -> Void
    let onPickPerson: (TeamMember) -> Void
    let onPick: (String, String) -> Void

    var body: some View {
        JumpPaletteView(
            targets: JumpTargets.build(
                chats: chats.chats, teams: teams.teams),
            initialQuery: initialQuery,
            searchStore: search,
            chatNameFor: chatNameFor,
            onPickMessage: onPickMessage,
            filePeople: filePeople,
            onPickFile: onPickFile, onPickPerson: onPickPerson,
            recents: recents,
            onPick: onPick)
    }
}

/// Forward sheet, live on the list stores (same as above).
struct ForwardSheetLive: View {
    let message: ChatMessage
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var teams: TeamsViewModel
    let initialQuery: String
    let onPick: (String, String) -> Void

    var body: some View {
        ForwardSheet(
            message: message,
            targets: ForwardPicker.targets(
                chats: chats.chats, teams: teams.teams),
            initialQuery: initialQuery,
            onPick: onPick)
    }
}

/// Forward sheet (om-msgactions): the jump palette re-targeted — same
/// fuzzy rows + keys, with a quote header naming the bubble being sent.
/// Picking sends the bubble text to that chat (conv.forward).
struct ForwardSheet: View {
    let message: ChatMessage
    let targets: [JumpTarget]
    let initialQuery: String
    let onPick: (String, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(DietColor.textSecondaryColor)
                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                    Text("Forward to…")
                        .font(DietType.headline)
                        .foregroundStyle(DietColor.textPrimaryColor)
                    Text("\(message.sender): \(MessageActions.forwardPreview(for: message))")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(2)
                }
                Spacer(minLength: DietSpace.sm)
            }
            .padding(DietSpace.md)
            DietDividerH()
            JumpPaletteView(
                targets: targets, initialQuery: initialQuery,
                verb: "forward", onPick: onPick)
        }
    }
}

/// Slim status bar (om-statusbar): Live dot + feed errors only. All
/// counters moved to the Diagnostics window (Window ▸ Diagnostics);
/// the dot's tooltip/VoiceOver label carries the shared feed line.
struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: DietSpace.sm) {
            Circle().fill(feedColor)
                .frame(width: DietSpace.sm, height: DietSpace.sm)
                .help(feedText)
                .accessibilityLabel(feedText)
            if let err = state.feedError {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .lineLimit(1)
            }
            Spacer()
            if !state.isDemo {
                AccountSwitcherView(
                    accounts: state.accounts,
                    onSelect: { state.switchAccount(to: $0) },
                    onAdded: { state.completePendingAdd($0) },
                    onOpenWindow: { state.pendingAccountWindowID = $0 })
            }
        }
        .padding(.horizontal, DietSpace.sm)
        .padding(.vertical, DietSpace.xs)
        .background(DietColor.windowColor)
    }

    private var feedColor: Color {
        switch state.feedState {
        case .live: Color(nsColor: DietColor.success)
        case .retryWait: Color(nsColor: DietColor.warning)
        case .stopped: DietColor.textTertiaryColor
        }
    }

    private var feedText: String {
        DiagnosticsFormat.feedLine(
            state: state.feedState, events: state.feedEvents,
            polls: state.feedPolls, resyncs: state.feedResyncs)
    }
}
