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
// --chat preselects (or opens directly when absent from the list).
// --say auto-sends once into the open chat. In live mode that is a REAL
// send via core — never use it on shared chats for testing.
// --show-about / --show-settings / --show-av open those windows at launch (shot hooks).
// --show-settings-keywords opens the sanitized fixed Settings view
// scrolled to the Keyword alerts section (R6 shot hook, offline).
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
// --show-notes opens the conversation on the Notes tab (shot hook).
// --show-jump opens the Cmd+K jump palette at launch (shot hook).
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
// demo offline; seed ~/.config/ostmac/scheduled.json for queue rows).
// --show-notif-live injects one canned trouter event through the real
// live path (rules → banner) and logs the decision + delivered
// readback (om-notif-live proof hook, demo offline; ignored live).
// --show-popout pops a second chat beside the main selection at launch
// (e1-popout shot hook, offline with --demo); --popout-chat <id> picks
// which chat (else the first row that is not the main selection).
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
            AvPanelView(screenShare: state.screenShare)
        }
        .defaultSize(width: 600, height: 740)
        Window("Call", id: AppIdentity.callWindowID) {
            InCallView(call: state.call)
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
        // e1-popout: one value-driven window per popped chat (re-pop of
        // the same id focuses the existing window — no dups). WindowGroup
        // carries the value API (plain Window has no `for:` overload).
        WindowGroup(Text("Chat"), id: AppIdentity.chatPopoutID, for: String.self) { value in
            if let chatID = value.wrappedValue {
                PopOutRootView(state: state, chatID: chatID)
            }
        }
        .defaultSize(width: 560, height: 640)
        Settings {
            if CommandLine.arguments.contains("--show-settings-keywords") {
                // Shot hook (R6): fixed sanitized view (no live account
                // rows), scrolled to Keyword alerts; rules load from the
                // seeded rules.json like the live store.
                SettingsView(account: AccountInfo(
                    signedIn: false, detail: "Signed out (demo shot)"))
            } else {
                SettingsView(
                    auth: state.auth, catchUp: state.catchUp, notifs: state.notifs,
                    rules: state.rules, chats: state.chats,
                    quiet: state.quietHours, blocked: state.blocked,
                    accounts: state.accounts,
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
        }
        CommandGroup(after: .windowList) {
            Button("Diagnostics") { openWindow(id: AppIdentity.diagWindowID) }
        }
    }
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
    let conv = ConversationStore()
    /// Pop-out registry (e1-popout): visible chat ids + per-chat stores +
    /// draft cache, bound to the main store for send mirroring.
    let popouts = PopOutStore()
    /// Message search (om-ja-search): the jump palette's Messages scope
    /// searches through this store. Demo runs substring-over-fixtures
    /// (offline); live hits Graph via core.
    let messageSearch: MessageSearchStore
    /// File + people search (om-jb-filesearch): the jump palette's
    /// Files/People sections search through this store. Demo runs
    /// substring-over-fixtures (offline); live hits Graph via core.
    let filePeople: FilePeopleSearchStore
    let shared = SharedFilesStore()
    let feed = RealtimeFeed()
    let typing = TypingStore()
    let notifs = MessageNotifications()
    let quietHours = QuietHoursStore()
    /// d2-send: per-chat snooze expiries + the scheduled-send queue.
    let snooze = SnoozeStore()
    let scheduled = ScheduledSendStore()
    // om-mention-alerts: the Mentions row count owns the Dock tile, so
    // unread counts stay sidebar-only here (per-chat badges + Diagnostics).
    let unread = UnreadStore(dock: NullDockBadge())
    let mentions = MentionStore()
    let receipts = ReceiptStore()
    /// Rebuilt per account on switch (d1-accounts).
    @Published var pinnedMessages: PinnedMessageStore
    let auth = AuthViewModel()
    let presence = PresenceStore()
    let call: CallStore
    /// Rebuilt per account on switch (d1-accounts).
    @Published var history = CallHistoryStore()
    let meeting = MeetingRosterStore()
    /// Rebuilt per account on switch (d1-accounts).
    @Published var meetingChat = MeetingChatStore()
    /// Multi-account list + per-account VMs (d1-accounts). The `auth`
    /// VM above is the live gate object, repointed at the active
    /// profile on every switch (stable identity for all observers).
    let accounts = AccountStore()
    /// True between an account switch/add and its quiet reload landing
    /// (keeps the gate open across the `.unknown` repoint beat).
    @Published var switchingAccount = false
    let screenShare = ScreenShareModel()
    let notes = NotesStore()
    let showNotes: Bool
    let catchUp: CatchUpStore
    /// --show-catchup: long demo thread + canned summary, sheet auto-opens.
    let showCatchUp: Bool
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
    @Published var showJump = false
    @AppStorage("selectedChatID") private var persistedSelection: String?

    private let preselectID: String?
    private let preselectName: String?
    private let autoSay: String?
    /// --popout-chat value (e1-popout shot hook: which chat to pop).
    private let popoutShotID: String?
    private var cancellables = Set<AnyCancellable>()
    /// Chat-list wiring (rebuilt with `chats` on account switch).
    private var chatsCancellables = Set<AnyCancellable>()
    private var stateTimer: Timer?
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
        isDemo = args.contains("--demo") || args.contains("--demo-rich")
            || args.contains("--demo-reactions") || args.contains("--show-sidebarchurn")
            || args.contains("--demo-botposts") || args.contains("--show-pins")
            || args.contains("--demo-showcase")
            || args.contains("--show-folders") || args.contains("--show-folders-manage")
        showNotes = args.contains("--show-notes")
        showJump = args.contains("--show-jump") // shot hook: palette open at launch
        call = CallStore(demo: isDemo)
        showCatchUp = args.contains("--show-catchup") || args.contains("--show-catchup-ondevice")
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
        } else if showHistory {
            preselectID = DemoData.historyID
        } else if args.contains("--show-reply") {
            preselectID = DemoData.repliesID
        } else if args.contains("--show-pins") {
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
        filePeople = isDemo
            ? FilePeopleSearchStore(
                fileSearcher: { query, _ in DemoData.fileSearchResponse(for: query) },
                peopleSearcher: { query, _ in DemoData.peopleSearchResponse(for: query) })
            : FilePeopleSearchStore()
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
                recordingLookup: Self.demoRecordingLookup())
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
            mentions.adopt(DemoData.mentionedChatIDs)
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
        popouts.bind(main: conv) // e1-popout: send mirroring both ways
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
        call.$call
            .receive(on: DispatchQueue.main)
            .sink { [weak self] c in
                Task { @MainActor [weak self] in
                    self?.history.noteActiveCall(c)
                }
            }
            .store(in: &cancellables)
        // om-notif: banner click opens the chat; inline reply sends.
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifOpenChat, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?["chatID"] as? String else { return }
            Task { @MainActor [weak self] in
                let name = self?.chats.chat(id: id)?.name
                self?.jump(chatID: id, chatName: name ?? "Conversation")
            }
        }
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifReply, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?["chatID"] as? String,
                  let text = note.userInfo?["text"] as? String
            else { return }
            Task { @MainActor [weak self] in self?.sendFromNotification(chatID: id, text: text) }
        }
        // d1-accounts: ordered switch stages (drain → flip → reset →
        // resume). Demo never switches (single canned identity).
        accounts.hooks = AccountSwitchHooks(
            drainRealtime: { [weak self] in self?.feed.stop() },
            resetForAccount: { [weak self] record in
                self?.resetStoresForAccount(record)
            },
            resume: { [weak self] in self?.repointAuthToActive() },
            removeCaches: { record in
                AccountCaches.remove(accountID: record.id)
            },
            emptied: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.auth.refreshStatus()
                }
            }
        )
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

    /// Call-history redial wiring (re-run after rebuild).
    private func wireHistory() {
        history.onRedial = { [weak self] record in
            Task { @MainActor [weak self] in self?.redial(record) }
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
        history = CallHistoryStore(key: CallHistoryStore.key(for: id))
        wireHistory()
        meetingChat = makeMeetingChat(accountID: id)
        teams.resetForAccount()
        presence.clear()
        typing.clear()
        meeting.clear()
        unread.markAllRead()
        mentions.markAllRead()
        receipts.clear()
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
            if let active = accounts.activeID {
                _ = try? RustCore.profileSet(active)
                auth.repoint(profile: active)
            }
            await auth.refreshStatus()
            signedIn = auth.isSignedIn
            accounts.refreshAll()
        }
        await openContentIfAllowed()
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
        if CommandLine.arguments.contains("--show-transcripts-showing") {
            transcripts.selectAndShowFirst()
        }
        await meetings.load()
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
            chats.selectedChatID = id // sink opens it
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
        // The 2s tick runs in demo too (d2-send: the scheduled queue and
        // the snooze sweep are client-side in both modes; the tick
        // publishes nothing while idle, so demo stays still). Starts
        // after the open above so launch catch-up delivers into the
        // open chat (own-bubble) instead of racing it.
        refreshFeedStatus()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
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

    func shutdown() {
        stateTimer?.invalidate()
        stateTimer = nil
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

    /// Sidebar + channel name for one conversation id (hit subtitles and
    /// jump headers share it). Unknown ids fall back to the generic label.
    func displayName(for chatID: String) -> String {
        chatNameOrNil(for: chatID) ?? "Conversation"
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
        openChatID = id
        if SelectionRestore.shouldPersist(chatID: id) {
            persistedSelection = id
        }
        unread.markRead(chatID: id) // om-notifbadge + om-markunread: opening marks read (counts + horizon override)
        mentions.markRead(chatID: id) // om-mentions: opening clears the flag
        if isDemo {
            // om-receipts: demo peers read through the tail (offline Seen).
            if let last = DemoData.messages(for: id).last {
                receipts.adopt(threadID: id, peers: ["demo-peer": last.id])
                receipts.noteSent(chatID: id, messageID: last.id)
            }
            let name = chatName ?? DemoData.name(for: id) ?? "Conversation"
            var msgs = DemoData.messages(for: id)
            if showCatchUp { msgs = Self.longThread(from: msgs) }
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
        // om-nc-delivery: the rules decision below owns the single banner
        // (maybeNotify); no second post here — one event, one banner max.
        // om-quiet-hours: snapshot quiet ONCE per event; the banner path
        // below obeys it (banners/sounds drop; unread pauses too —
        // quiet-hours skips never accrue).
        let quiet = quietHours.isQuietNow
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
    }

    /// Owner MRI for live-event matching: configured value wins, else
    /// the Graph-learned one (nil until it lands — the display-name
    /// backup covers the gap). Shared by the rules decision and the
    /// mention tracker so both gates see the same identity.
    private var resolvedOwnerMRI: String? {
        rules.config.owner.mri.isEmpty ? ownerMRI : rules.config.owner.mri
    }

    /// One rules decision for a live event (owns the meeting-start
    /// window claim). Owner identity prefers configured/learned MRI with
    /// a live display-name backup. DND reads the own Teams presence;
    /// quiet reads the local store (schedule or manual DND — both
    /// suppress mentions too).
    private func rulesDecision(for msg: RealtimeMessage, chatName: String) -> ChatFilter.Decision {
        var cfg = rules.config
        if let own = conv.ownDisplayName, !own.isEmpty { cfg.owner.displayName = own }
        return ChatFilter.decide(
            message: msg, chatDisplayName: chatName, ownerMRI: resolvedOwnerMRI,
            rules: cfg, meetingDedup: &meetingDedup, now: Date(),
            dndActive: MentionAlert.isDND(ownAvailability: presence.own?.availability),
            quietActive: quietHours.isQuietNow,
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
    private func maybeNotify(
        _ msg: RealtimeMessage, chatName: String,
        decision: ChatFilter.Decision, mutedChatIDs: Set<String>
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
            var cfg = rules.config
            if let own = conv.ownDisplayName, !own.isEmpty { cfg.owner.displayName = own }
            let eff = cfg.effective(forChat: chatName)
            let mined = msg.mentions
            let ownerHit = Mentions.mentionsOwner(
                mined, ownerMRI: resolvedOwnerMRI,
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
            isMention: breakthrough, subtitle: subtitle)
        else { return }
        Notifier.shared.post(
            title: banner.title, body: banner.body,
            id: banner.id.isEmpty ? nil : banner.id, chatID: banner.chatID,
            sound: banner.sound, isMention: banner.isMention, subtitle: banner.subtitle)
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
        Notifier.shared.onOpenChat = { [weak self] chatID in
            guard let strongSelf = self else { return }
            await MainActor.run {
                let name = strongSelf.chats.chat(id: chatID)?.name ?? "Conversation"
                strongSelf.jump(chatID: chatID, chatName: name)
            }
        }
        Notifier.shared.onReply = { chatID, text in
            do {
                _ = try RustCore.send(chatID: chatID, text: text)
                return .success(())
            } catch {
                return .failure(error)
            }
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

    /// Inline reply from a notification: optimistic bubble when the chat
    /// is open, direct core send otherwise (no chat switch).
    private func sendFromNotification(chatID id: String, text: String) {
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
            typing.clear()
            meeting.clear()
            meetingChat.clear()
            unread.markAllRead() // om-notifbadge: counts clear on sign-out
            mentions.markAllRead() // om-mention-alerts: flags + dock clear on sign-out
            receipts.clear() // om-receipts: positions clear on sign-out
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
        ConversationView(
            store: state.popouts.store(for: chatID),
            presence: state.presence,
            call: state.call, shared: shared, notes: notes,
            catchUp: state.catchUp, typing: state.typing,
            receipts: state.receipts,
            pins: state.pinnedMessages,
            scheduled: state.scheduled,
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

/// Per-window title for value-driven pop-outs (the scene title is static,
/// so each window stamps its own chat name through its own view).
private struct PopoutTitleProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI stamps the static scene title at creation; the async
        // hop lands after it so the chat name wins and sticks.
        let name = name
        DispatchQueue.main.async {
            if view.window?.title != name { view.window?.title = name }
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

    /// Shot-hook section: --show-recordings/--show-planner win over --show-reminders
    /// wins over --show-teams. The create-sheet hooks also land on
    /// teams (the sheets hang there).
    static var initialSection: SidebarSection {
        let args = CommandLine.arguments
        if args.contains("--show-recordings") { return .recordings }
        if args.contains("--show-recordings-playing") { return .recordings }
        if args.contains("--show-transcripts") { return .transcripts }
        if args.contains("--show-transcripts-showing") { return .transcripts }
        if args.contains("--show-planner") { return .planner }
        if args.contains("--show-reminders") { return .reminders }
        if args.contains("--show-teams") { return .teams }
        if args.contains("--show-channel-create") { return .teams }
        if args.contains("--show-team-create") { return .teams }
        return .chats
    }

    var body: some View {
        VStack(spacing: 0) {
            CallBanner(store: state.call) {
                openWindow(id: AppIdentity.callWindowID)
            }
            if state.isDemo || state.switchingAccount || state.auth.state.allowsContent {
                NavigationSplitView {
                    SidebarColumn(
                        chats: state.chats, teams: state.teams,
                        reminders: state.reminders, planner: state.planner,
                        recordings: state.recordings,
                        transcripts: state.transcripts, shifts: state.shifts,
                        presence: state.presence,
                        unread: state.unread,
                        mentions: state.mentions,
                        rules: state.rules,
                        snooze: state.snooze,
                        openChatID: state.openChatID,
                        initialSection: RootView.initialSection,
                        initialFilter: OstMacAppMain.filterQuery(args: CommandLine.arguments),
                        channelCreateOpen: CommandLine.arguments.contains("--show-channel-create"),
                        teamCreateOpen: CommandLine.arguments.contains("--show-team-create"),
                        initialFolderID: state.folderShotSelection,
                        folderManageOpen: CommandLine.arguments.contains("--show-folders-manage"),
                        initialEditingRuleID: state.folderShotEditingRuleID,
                        onOpenChannel: { id, name in state.openChannel(channelID: id, channelName: name) },
                        onPopOut: { id in
                            if let target = state.popOut(chatID: id) {
                                openWindow(value: target)
                            }
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    if state.openChatID == nil {
                        emptyDetail
                    } else {
                        ConversationView(
                            store: state.conv, presence: state.presence,
                            call: state.call, shared: state.shared, notes: state.notes,
                            catchUp: state.catchUp, typing: state.typing,
                            receipts: state.receipts,
                            pins: state.pinnedMessages,
                            scheduled: state.scheduled,
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
                            onDraftChange: { state.popouts.saveDraft($0, for: state.openChatID ?? "") })
                            // Per-chat composer (e1-popout): drafts restore
                            // per thread instead of leaking across switches.
                            .id(state.openChatID)
                    }
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
        .sheet(isPresented: $state.showJump) {
            JumpPaletteSheet(
                chats: state.chats, teams: state.teams,
                search: state.messageSearch,
                filePeople: state.filePeople,
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
            if CommandLine.arguments.contains("--show-settings")
                || CommandLine.arguments.contains("--show-settings-keywords") {
                openSettings()
            }
            if OstMacAppMain.authStateName(args: CommandLine.arguments) != nil {
                openWindow(id: AppIdentity.authWindowID)
            }
        }
        .task { await state.startup() }
        .onDisappear { state.shutdown() }
    }

    /// Empty detail keeps the header row so the sidebar picker seam
    /// spans both columns (same row as the conversation header).
    private var emptyDetail: some View {
        VStack(spacing: 0) {
            DietHeaderBar { Color.clear }
            DietEmptyState(
                systemImage: "bubble.left.and.bubble.right",
                title: "Select a chat",
                message: "Pick a conversation in the sidebar, or press ⌘K to jump.")
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
                    onAdded: { state.completePendingAdd($0) })
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
