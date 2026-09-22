// OstMac — THE app (om-auth-gate): the main window is gated on the
// AuthViewModel 11-state gate — unsigned shows the full sign-in UI
// (device code, copy/open-browser, polling, expiry/refresh, sign-out)
// where the chats would be; chats, conversation, and the live feed
// stay parked until signedIn. Settings embeds the same shared model.
// --demo bypasses the gate fully offline.
//
// Usage:
//   OstMac [--demo | --demo-rich] [--chat <id> [--name <n>]] [--say <text>]
//          [--show-about] [--show-settings] [--auth-state <name>]
//          [--show-call incoming|active] [--show-av]
// --show-call seeds the call banner offline (demo state, no core calls).
// --demo runs fully offline (canned chats/messages, local send echo).
// --demo-rich is --demo preselected on the rich thread (mentions, code,
// edited + failed bubbles, Yesterday/Today separators).
// --chat preselects (or opens directly when absent from the list).
// --say auto-sends once into the open chat. In live mode that is a REAL
// send via core — never use it on shared chats for testing.
// --show-about / --show-settings / --show-av open those windows at launch (shot hooks).
// --show-teams opens the sidebar on the Teams browser (shot hook).
// --auth-state <name> opens the Auth window with a canned state, never
// touching core/network (names: signed-out, starting, code, polling,
// signed-in, expired, refreshing, refresh-failed, error). `--state` is
// an alias. Without it the Auth window shows the live session.
//
// Realtime routing: the Trouter socket is global (one feed for all
// chats), so switching chats does NOT restart the socket — the list
// ingests every event (preview refresh + reorder), while bubbles are
// filtered to the open chat (`isFor(chatID:)`). A resync gap
// re-fetches the open chat plus the list.
import Combine
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
        case "signed-in": .signedIn
        case "expired": .expired
        case "refreshing": .refreshing
        case "refresh-failed": .refreshFailed("refresh: token request failed (demo)")
        case "error": .error("device_start: network unreachable (demo)")
        default: .signedOut
        }
    }

    var body: some Scene {
        WindowGroup("OstMac") {
            RootView()
                .environmentObject(state)
        }
        .defaultSize(width: 1000, height: 640)
        Window("About OstMac", id: AppIdentity.aboutWindowID) {
            AboutView()
        }
        .defaultSize(width: 360, height: 340)
        .windowResizability(.contentSize)
        Window("OstMac Auth", id: AppIdentity.authWindowID) {
            if let cannedAuth {
                AuthView(model: cannedAuth)
            } else {
                AuthView(model: state.auth)
                    .task { await state.auth.refreshStatus() }
            }
        }
        .defaultSize(width: 440, height: 520)
        Window("Call A/V", id: AppIdentity.avWindowID) {
            AvPanelView()
        }
        .defaultSize(width: 600, height: 740)
        Settings {
            SettingsView(auth: state.auth)
        }
        .commands { OstMacCommands() }
    }
}

/// App menu: About opens our About window (standard panel replaced);
/// Settings… (from the Settings scene) and Quit stay automatic.
private struct OstMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About OstMac") { openWindow(id: AppIdentity.aboutWindowID) }
        }
        CommandMenu("Call") {
            Button("Call A/V Test") { openWindow(id: AppIdentity.avWindowID) }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let isDemo: Bool
    let chats: ChatListViewModel
    let teams: TeamsViewModel
    let conv = ConversationStore()
    let feed = RealtimeFeed()
    let auth = AuthViewModel()
    let presence = PresenceStore()
    let call: CallStore
    @Published var openChatID: String?
    @Published var signedIn: Bool?
    @Published var coreVersion = "?"
    @Published var initCode: Int32 = -99
    @Published var feedState: RealtimeFeed.State = .stopped
    @Published var feedEvents = 0
    @Published var feedResyncs = 0
    @Published var feedPolls = 0
    @Published var feedError: String?
    @AppStorage("selectedChatID") private var persistedSelection: String?

    private let preselectID: String?
    private let preselectName: String?
    private let autoSay: String?
    private var cancellables = Set<AnyCancellable>()
    private var stateTimer: Timer?
    private var started = false
    private var contentOpened = false

    init(args: [String]) {
        isDemo = args.contains("--demo") || args.contains("--demo-rich")
        call = CallStore(demo: isDemo)
        // Shot hook: --show-call incoming|active seeds the banner offline.
        if let i = args.firstIndex(of: "--show-call"), i + 1 < args.count {
            call.seedDemo(state: args[i + 1])
        }
        if let i = args.firstIndex(of: "--chat"), i + 1 < args.count {
            preselectID = args[i + 1]
        } else if args.contains("--demo-rich") {
            preselectID = DemoData.richID
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
            chats = ChatListViewModel(fetcher: { _ in DemoData.chatsResponse() })
            teams = TeamsViewModel(fetcher: { DemoData.teamsResponse() })
            presence.adoptOwn(DemoData.ownPresence())
            for (chatID, peer) in DemoData.peerPresence() {
                presence.adoptChatPeer(chatID: chatID, response: peer)
            }
        } else {
            chats = ChatListViewModel()
            teams = TeamsViewModel()
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
        await teams.load()
        if chats.state == .loaded {
            // Core's signed_in is aad-centric; a loaded list proves
            // working auth regardless.
            signedIn = true
        }
        // Restore: explicit --chat wins, else last selection.
        let target = preselectID ?? persistedSelection
        if let id = target {
            if chats.chats.contains(where: { $0.id == id }) {
                chats.selectedChatID = id // sink opens it
            } else {
                open(chatID: id, chatName: preselectName)
            }
        }
        if !isDemo {
            presence.refreshOwnSoon() // own dot; non-critical on failure
            feed.subscribe { [weak self] msg in
                Task { @MainActor [weak self] in self?.handleRealtime(msg) }
            }
            feed.onResync { [weak self] in
                Task { @MainActor [weak self] in self?.handleResync() }
            }
            feed.onCall { [weak self] ev in
                Task { @MainActor [weak self] in self?.call.ingest(ev) }
            }
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

    private func open(chatID id: String, chatName: String?) {
        openChatID = id
        persistedSelection = id
        if isDemo {
            let name = chatName ?? DemoData.name(for: id) ?? id
            conv.showDemo(
                chatID: id, chatName: name, messages: DemoData.messages(for: id),
                failed: DemoData.failedIDs(for: id))
        } else {
            conv.open(chatID: id, chatName: chatName)
        }
    }

    /// One live event: count it, refresh the list row (all chats),
    /// route the bubble to the open chat only.
    private func handleRealtime(_ msg: RealtimeMessage) {
        feedEvents += 1
        refreshFeedStatus()
        chats.ingest(realtime: msg)
        guard msg.isFor(chatID: openChatID) else { return }
        conv.ingest(realtime: msg)
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

    var body: some View {
        VStack(spacing: 0) {
            CallBanner(store: state.call)
            if state.isDemo || state.auth.state.allowsContent {
                NavigationSplitView {
                    SidebarColumn(
                        chats: state.chats, teams: state.teams,
                        presence: state.presence,
                        openChatID: state.openChatID,
                        initialSection: CommandLine.arguments.contains("--show-teams") ? .teams : .chats,
                        onOpenChannel: { id, name in state.openChannel(channelID: id, channelName: name) }
                    )
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    if state.openChatID == nil {
                        emptyDetail
                    } else {
                        ConversationView(
                            store: state.conv, presence: state.presence,
                            call: state.call,
                            isGroup: state.chats.selectedChat?.is_group ?? true)
                    }
                }
            } else {
                // Gate: the full 11-state sign-in where the chats would be.
                AuthView(model: state.auth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            StatusBar(call: state.call)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            // Shot hooks: open About/Settings/Auth/A-V windows from launch args.
            if CommandLine.arguments.contains("--show-about") {
                openWindow(id: AppIdentity.aboutWindowID)
            }
            if CommandLine.arguments.contains("--show-av") {
                openWindow(id: AppIdentity.avWindowID)
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

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Select a chat").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var call: CallStore

    var body: some View {
        HStack(spacing: 12) {
            Text("core \(state.coreVersion) · init=\(state.initCode)")
                .font(.caption).monospaced().foregroundStyle(.secondary)
            if let c = call.call, c.isActive {
                Text("call: \(c.state) · \(c.displayPeer)")
                    .font(.caption).monospaced().foregroundStyle(.green)
                    .lineLimit(1)
            } else if !state.isDemo, state.signedIn == true {
                Button("Echo test") { call.echo() }
                    .font(.caption)
                    .disabled(call.busy)
                    .help("Place the echo-bot test call (signaling only)")
            }
            if state.isDemo {
                Text("DEMO · offline")
                    .font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .clipShape(Capsule())
                PresencePicker(store: state.presence)
            } else {
                Text(state.signedIn.map { $0 ? "signed in" : "signed out" } ?? "auth ?")
                    .font(.caption).foregroundStyle(.secondary)
                PresencePicker(store: state.presence)
                HStack(spacing: 4) {
                    Circle().fill(feedColor).frame(width: 8, height: 8)
                    Text(feedText).font(.caption).monospaced()
                }
                if let err = state.feedError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var feedColor: Color {
        switch state.feedState {
        case .live: .green
        case .retryWait: .orange
        case .stopped: .gray
        }
    }

    private var feedText: String {
        switch state.feedState {
        case .live:
            "Live · \(state.feedEvents) new · \(state.feedPolls) polls · \(state.feedResyncs) resyncs"
        case .retryWait:
            "Connecting… (\(state.feedEvents) new · \(state.feedResyncs) resyncs)"
        case .stopped:
            "Realtime off"
        }
    }
}
