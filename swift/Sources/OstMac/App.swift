// Diet Teams — THE app (om-auth-gate): the main window is gated on the
// AuthViewModel 13-state gate — unsigned shows the full sign-in UI
// (device code, copy/open-browser, polling, expiry/refresh, sign-out)
// where the chats would be; chats, conversation, and the live feed
// stay parked until signedIn. Settings embeds the same shared model.
// --demo bypasses the gate fully offline.
//
// Usage:
//   Diet Teams [--demo | --demo-rich | --demo-reactions | --demo-botposts] [--chat <id> [--name <n>]] [--say <text>]
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
// --chat preselects (or opens directly when absent from the list).
// --say auto-sends once into the open chat. In live mode that is a REAL
// send via core — never use it on shared chats for testing.
// --show-about / --show-settings / --show-av open those windows at launch (shot hooks).
// --show-diagnostics opens the Diagnostics window at launch (shot hook).
// --av-mic-denied seeds the Call A/V panel's mic-denied hint (shot hook).
// --show-teams opens the sidebar on the Teams browser (shot hook).
// --show-shared opens the conversation on the Shared files tab (shot hook).
// --show-reminders opens the sidebar on the Reminders browser (shot hook).
// --show-notes opens the conversation on the Notes tab (shot hook).
// --show-jump opens the Cmd+K jump palette at launch (shot hook).
// --show-forward opens the forward sheet (jump palette re-targeted at a
// demo bubble) at launch (om-msgactions shot hook, offline).
// --jump-query <q> / --filter-query <q> preseed the palette/sidebar
// filters (shot hooks).
// --show-gif opens the GIF picker popover at launch (shot hook).
// --show-picker opens the reaction more-picker popover on the first
// reacted bubble at launch (om-react-polish shot hook, offline).
// --show-catchup stretches the demo thread past 20 messages and
// auto-opens the catch-up sheet with a canned summary (shot hook,
// offline, throwaway defaults — never the real ones).
// --show-reply opens the demo replies thread with the compose-reply
// chip armed on Tom's question (shot hook, offline).
// --show-sidebarchurn swaps the demo list for the churn dataset
// (meeting + bot + system rows) and folds a beacon burst after load,
// so the sidebar shows the stable result (shot hook, offline).
// --show-history preselects the 3-day history thread (with --demo;
// shot hook, offline). --show-history-error opens it empty with a
// canned fetch failure + Try Again (shot hook, offline).
// --scroll-to <message-id> lands the initial scroll on that bubble
// (scroll-state shots; consumed by ConversationView).
// --show-edit / --show-delete open the edit sheet / delete confirm for
// the first own bubble at launch (om-editdel shot hooks, demo offline).
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
import Combine
import DietDesign
import Foundation
import OstMacChatList
import OstMacCore
import SwiftUI

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
        WindowGroup("Diet Teams") {
            RootView()
                .environmentObject(state)
        }
        .defaultSize(width: 1000, height: 640)
        Window("About Diet Teams", id: AppIdentity.aboutWindowID) {
            AboutView()
        }
        .defaultSize(width: 360, height: 340)
        .windowResizability(.contentSize)
        Window("Diet Teams Auth", id: AppIdentity.authWindowID) {
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
            AvPanelView()
        }
        .defaultSize(width: 600, height: 740)
        Window("Diagnostics", id: AppIdentity.diagWindowID) {
            DiagnosticsView()
                .environmentObject(state)
        }
        .defaultSize(width: 440, height: 480)
        Settings {
            SettingsView(auth: state.auth, catchUp: state.catchUp, notifs: state.notifs)
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
            Button("About Diet Teams") { openWindow(id: AppIdentity.aboutWindowID) }
        }
        CommandGroup(after: .appInfo) {
            Button("Sign In…") { openWindow(id: AppIdentity.authWindowID) }
                .keyboardShortcut("I", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("Call") {
            Button("Call A/V Test") { openWindow(id: AppIdentity.avWindowID) }
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
    let chats: ChatListViewModel
    let teams: TeamsViewModel
    let reminders: RemindersViewModel
    let conv = ConversationStore()
    let shared = SharedFilesStore()
    let feed = RealtimeFeed()
    let notifs = MessageNotifications()
    let unread = UnreadStore()
    let mentions = MentionStore()
    let receipts = ReceiptStore()
    let auth = AuthViewModel()
    let presence = PresenceStore()
    let call: CallStore
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
    /// --show-sidebarchurn: churn dataset + post-load beacon burst.
    let showSidebarChurn: Bool
    /// --show-history-error: demo history thread, empty + canned fetch error.
    let showHistoryError: Bool
    /// History shot launch (--show-history*): memory key store, so the
    /// shot never touches the real keychain (no SecurityAgent prompt).
    let showHistory: Bool
    @Published var openChatID: String?
    @Published var signedIn: Bool?
    @Published var coreVersion = "?"
    @Published var initCode: Int32 = -99
    @Published var feedState: RealtimeFeed.State = .stopped
    @Published var feedEvents = 0
    @Published var feedResyncs = 0
    @Published var feedPolls = 0
    @Published var feedError: String?
    @Published var showJump = false
    @AppStorage("selectedChatID") private var persistedSelection: String?

    private let preselectID: String?
    private let preselectName: String?
    private let autoSay: String?
    private var cancellables = Set<AnyCancellable>()
    private var stateTimer: Timer?
    private var started = false
    private var contentOpened = false
    // om-rules: notify/skip rules over the live feed (file-loaded once at
    // launch; edits need a relaunch). meetingDedup collapses meeting
    // bursts; ownerMRI is learned async (name backup covers the gap).
    private var meetingDedup = MeetingStartDedup()
    private var rulesConfig = RulesConfig.loadBestEffort()
    private var ownerMRI: String?

    init(args: [String]) {
        isDemo = args.contains("--demo") || args.contains("--demo-rich")
            || args.contains("--demo-reactions") || args.contains("--show-sidebarchurn")
            || args.contains("--demo-botposts")
        showNotes = args.contains("--show-notes")
        showJump = args.contains("--show-jump") // shot hook: palette open at launch
        call = CallStore(demo: isDemo)
        showCatchUp = args.contains("--show-catchup")
        showForward = args.contains("--show-forward")
        showReply = args.contains("--show-reply")
        showSidebarChurn = args.contains("--show-sidebarchurn")
        showHistoryError = args.contains("--show-history-error")
        showHistory = args.contains("--show-history") || showHistoryError
        if showCatchUp {
            // Shot hook only: throwaway defaults (never the real ones),
            // canned summary, no network.
            let canned = CatchUpCannedTransport(stub: Self.catchUpDemoSummary)
            let store = CatchUpStore(
                cliTransport: canned,
                defaults: UserDefaults(suiteName: "shot-catchup") ?? .standard,
                keyStore: CatchUpMemoryKeyStore())
            store.adopt(CatchUpConfig(enabled: true, apiKey: "demo"))
            catchUp = store
        } else if showHistory {
            // Shot hook only: memory key store, never the real keychain
            // (--show-catchup precedent; no SecurityAgent prompt).
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
        } else if args.contains("--demo-rich") {
            preselectID = DemoData.richID
        } else if args.contains("--demo-reactions") {
            preselectID = DemoData.reactionsID
        } else if args.contains("--demo-botposts") {
            preselectID = DemoData.botpostsID
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
        if isDemo {
            // Shot hook: the churn dataset swaps the whole list (the
            // standard demo rows + count assertions stay untouched).
            let seed = showSidebarChurn
                ? DemoData.churnChatsResponse() : DemoData.chatsResponse()
            chats = ChatListViewModel(fetcher: { _ in seed })
            teams = TeamsViewModel(fetcher: { DemoData.teamsResponse() })
            reminders = RemindersViewModel(
                listsFetcher: { DemoData.remindersResponse() },
                tasksFetcher: { DemoData.reminderTasksResponse(for: $0) },
                localEdits: true)
            presence.adoptOwn(DemoData.ownPresence())
            for (chatID, peer) in DemoData.peerPresence() {
                presence.adoptChatPeer(chatID: chatID, response: peer)
            }
            mentions.adopt(DemoData.mentionedChatIDs)
        } else {
            chats = ChatListViewModel()
            teams = TeamsViewModel()
            reminders = RemindersViewModel()
        }
        chats.$selectedChatID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                Task { @MainActor [weak self] in self?.openSelected(id) }
            }
            .store(in: &cancellables)
        // Single reaction point for the gate: every auth transition
        // (gate, Settings, Auth window — same model) runs authChanged,
        // which flips the gate via the signedIn/contentOpened flags.
        auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                Task { @MainActor [weak self] in self?.authChanged(s) }
            }
            .store(in: &cancellables)
        // om-receipts: forward receipt changes so Diagnostics counts update.
        receipts.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // om-notif: banner click opens the chat; inline reply sends.
        _ = NotificationCenter.default.addObserver(
            forName: .omNotifOpenChat, object: nil, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?["chatID"] as? String else { return }
            Task { @MainActor [weak self] in
                let name = self?.chats.chats.first(where: { $0.id == id })?.name
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
    }

    func startup() async {
        guard !started else { return }
        started = true
        coreVersion = RustCore.version()
        initCode = RustCore.initialize()
        if isDemo {
            signedIn = true // demo bypasses the gate (offline canned data)
        } else {
            await auth.refreshStatus()
            signedIn = auth.isSignedIn
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
                Task { @MainActor [weak self] in self?.call.ingest(ev) }
            }
            notifs.attach()
            await notifs.requestAuthorization()
            feed.start()
            refreshFeedStatus()
            stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshFeedStatus() }
            }
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
            return
        }
        guard id != openChatID else { return } // already open (direct --chat path)
        let name = chats.chats.first(where: { $0.id == id })?.name ?? preselectName
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

    private func open(chatID id: String, chatName: String?) {
        // Demo threads never load outside the demo flags (a stale
        // demo-react default 404d the installed build); demo
        // selections never reach shared defaults either.
        guard isDemo || !DemoData.isDemoID(id) else { return }
        openChatID = id
        if SelectionRestore.shouldPersist(chatID: id) {
            persistedSelection = id
        }
        unread.markRead(chatID: id) // om-notifbadge: opening marks read
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
            notes.showDemo()
        } else {
            conv.open(chatID: id, chatName: chatName)
            // Notes scope: channels read the team (M365 group) notebook;
            // plain chats read the user's own OneNote (no shared notebook).
            notes.open(groupID: teamID(forChannel: id))
            // om-receipts: peer positions for Seen state (no list refresh).
            receipts.refresh(threadID: id)
        }
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
    - Priya asked that edited messages update in place, not re-sort.
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
    private func handleRealtime(_ msg: RealtimeMessage) {
        feedEvents += 1
        refreshFeedStatus()
        chats.ingest(realtime: msg)
        // om-notif: banner for non-open, non-own, non-edit events.
        Task {
            await notifs.handle(
                msg,
                chatName: chats.chats.first(where: { $0.id == msg.chatID })?.name,
                openChatID: openChatID,
                ownDisplayName: conv.ownDisplayName)
        }
        if let mri = msg.senderID,
           msg.sender != conv.ownDisplayName,
           chats.chats.first(where: { $0.id == msg.chatID })?.is_group == false
        {
            Task { await presence.refreshChatPeerMri(chatID: msg.chatID, mri: mri) }
        }
        // om-rules + om-notifbadge: ONE rules decision per event drives
        // both the banner (all chats, open one included — TN parity) and
        // the unread counts (skips and the open chat never accrue).
        let chatName = chats.chats.first(where: { $0.id == msg.chatID })?.name ?? ""
        let decision = rulesDecision(for: msg, chatName: chatName)
        unread.ingest(decision: decision, chatID: msg.chatID, openChatID: openChatID)
        mentions.ingest(
            realtime: msg, ownName: conv.ownDisplayName,
            ownerMRI: resolvedOwnerMRI, openChatID: openChatID)
        maybeNotify(msg, chatName: chatName, decision: decision)
        guard msg.isFor(chatID: openChatID) else { return }
        conv.ingest(realtime: msg)
        // om-receipts: a peer reply implies they read through our tail;
        // refresh Seen state (no list refresh — receipts only).
        if !msg.isEdit, !msg.text.isEmpty {
            receipts.refresh(threadID: msg.chatID)
        }
    }

    /// Owner MRI for live-event matching: configured value wins, else
    /// the Graph-learned one (nil until it lands — the display-name
    /// backup covers the gap). Shared by the rules decision and the
    /// mention tracker so both gates see the same identity.
    private var resolvedOwnerMRI: String? {
        rulesConfig.owner.mri.isEmpty ? ownerMRI : rulesConfig.owner.mri
    }

    /// One rules decision for a live event (owns the meeting-start
    /// window claim). Owner identity prefers configured/learned MRI with
    /// a live display-name backup.
    private func rulesDecision(for msg: RealtimeMessage, chatName: String) -> ChatFilter.Decision {
        var cfg = rulesConfig
        if let own = conv.ownDisplayName, !own.isEmpty { cfg.owner.displayName = own }
        return ChatFilter.decide(
            message: msg, chatDisplayName: chatName, ownerMRI: resolvedOwnerMRI,
            rules: cfg, meetingDedup: &meetingDedup, now: Date())
    }

    /// Rules-based banner for one live event (om-rules: TN ChatFilter
    /// port). Posts through Notifier only on .notify. Respects the
    /// Settings banner toggle (om-settings-trim) so OFF is really off.
    private func maybeNotify(_ msg: RealtimeMessage, chatName: String, decision: ChatFilter.Decision) {
        guard notifs.enabled else { return }
        guard case .notify(let reason) = decision else { return }
        let title: String
        let body: String
        if reason == ChatFilter.meetingStartingReason {
            // Synthesized body (raw beacons/blobs never shown).
            if chatName.isEmpty || chatName == msg.chatID {
                title = "Teams meeting"
                body = "Meeting starting"
            } else {
                title = chatName
                body = "Meeting starting: \(chatName)"
            }
        } else if chatName.isEmpty || chatName == msg.chatID {
            title = msg.sender.isEmpty ? "Teams message" : msg.sender
            body = msg.text
        } else {
            title = msg.sender.isEmpty ? chatName : "\(msg.sender) in \(chatName)"
            body = msg.text
        }
        Notifier.shared.post(
            title: title, body: body,
            id: msg.msgId.isEmpty ? nil : msg.msgId, chatID: msg.chatID)
    }

    /// Wire the notifier: Reply posts through core send, Open chat jumps.
    /// Live mode only (demo never starts the feed, so never notifies).
    private func setupNotifier() {
        Notifier.shared.setup()
        Notifier.shared.onOpenChat = { [weak self] chatID in
            guard let strongSelf = self else { return }
            await MainActor.run {
                let name = strongSelf.chats.chats.first(where: { $0.id == chatID })?.name ?? "Conversation"
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

    private func refreshFeedStatus() {
        feedState = feed.currentState
        feedPolls = feed.pollCount
        feedError = feed.lastError
        if !isDemo { call.refresh() } // re-read slot (place/accept landed?)
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
            if contentOpened {
                chats.refresh()
                teams.refresh()
                reminders.refresh()
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
            feed.stop()
            presence.clear()
            unread.markAllRead() // om-notifbadge: dock clears on sign-out
            mentions.markAllRead() // om-mentions: flags clear on sign-out
            receipts.clear() // om-receipts: positions clear on sign-out
            refreshFeedStatus()
        default:
            break
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Shot-hook section: --show-reminders wins over --show-teams.
    static var initialSection: SidebarSection {
        let args = CommandLine.arguments
        if args.contains("--show-reminders") { return .reminders }
        if args.contains("--show-teams") { return .teams }
        return .chats
    }

    var body: some View {
        VStack(spacing: 0) {
            CallBanner(store: state.call)
            if state.isDemo || state.auth.state.allowsContent {
                NavigationSplitView {
                    SidebarColumn(
                        chats: state.chats, teams: state.teams,
                        reminders: state.reminders,
                        presence: state.presence,
                        unread: state.unread,
                        mentions: state.mentions,
                        openChatID: state.openChatID,
                        initialSection: RootView.initialSection,
                        initialFilter: OstMacAppMain.filterQuery(args: CommandLine.arguments),
                        onOpenChannel: { id, name in state.openChannel(channelID: id, channelName: name) }
                    )
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    if state.openChatID == nil {
                        emptyDetail
                    } else {
                        ConversationView(
                            store: state.conv, presence: state.presence,
                            call: state.call, shared: state.shared, notes: state.notes,
                            catchUp: state.catchUp, receipts: state.receipts,
                            isGroup: state.chats.selectedChat?.is_group ?? true,
                            initialTab: CommandLine.arguments.contains("--show-shared") ? 1
                                : (state.showNotes ? 2 : 0),
                            catchUpOpen: state.showCatchUp,
                            onForward: { state.beginForward($0) },
                            editOpen: CommandLine.arguments.contains("--show-edit"),
                            deleteOpen: CommandLine.arguments.contains("--show-delete"))
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
        .sheet(isPresented: $state.showJump) {
            JumpPaletteView(
                targets: JumpTargets.build(chats: state.chats.chats, teams: state.teams.teams),
                initialQuery: OstMacAppMain.jumpQuery(args: CommandLine.arguments)
            ) { id, name in
                state.showJump = false
                state.jump(chatID: id, chatName: name)
            }
        }
        .sheet(item: $state.forwardMessage) { msg in
            ForwardSheet(
                message: msg,
                targets: JumpTargets.build(chats: state.chats.chats, teams: state.teams.teams),
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
            if CommandLine.arguments.contains("--show-diagnostics") {
                openWindow(id: AppIdentity.diagWindowID)
            }
            if CommandLine.arguments.contains("--show-settings") {
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
