// OstMac — THE app (om-app-union): sidebar chat list + conversation
// detail + live realtime feed in one window; real identity (About
// window, Settings shell, app menu); full authux sign-in (device code,
// copy/open-browser, polling, expiry/refresh, sign-out) in a sheet.
//
// Merges the deleted shells: OstMacApp lib (About/Settings/identity —
// OstMacRootView was a strict subset of RootView) and OstMacAuth
// (--auth-state canned states + live AuthView window).
//
// Usage:
//   OstMac [--demo | --demo-rich] [--chat <id> [--name <n>]] [--say <text>]
//          [--show-about] [--auth-state <name>]
// --demo runs fully offline (canned chats/messages, local send echo).
// --demo-rich is --demo preselected on the rich thread (mentions, code,
// edited + failed bubbles, Yesterday/Today separators).
// --chat preselects (or opens directly when absent from the list).
// --say auto-sends once into the open chat. In live mode that is a REAL
// send via core — never use it on shared chats for testing.
// --show-about opens the About window at launch (shot hook).
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
        Settings {
            SettingsView()
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
    }
}

@MainActor
final class AppState: ObservableObject {
    let isDemo: Bool
    let chats: ChatListViewModel
    let conv = ConversationStore()
    let feed = RealtimeFeed()
    let auth = AuthViewModel()
    @Published var openChatID: String?
    @Published var signedIn: Bool?
    @Published var coreVersion = "?"
    @Published var initCode: Int32 = -99
    @Published var feedState: RealtimeFeed.State = .stopped
    @Published var feedEvents = 0
    @Published var feedResyncs = 0
    @Published var feedPolls = 0
    @Published var feedError: String?
    @Published var showSignIn = false
    @AppStorage("selectedChatID") private var persistedSelection: String?

    private let preselectID: String?
    private let preselectName: String?
    private let autoSay: String?
    private var cancellables = Set<AnyCancellable>()
    private var stateTimer: Timer?
    private var started = false

    init(args: [String]) {
        isDemo = args.contains("--demo") || args.contains("--demo-rich")
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
        } else {
            chats = ChatListViewModel()
        }
        chats.$selectedChatID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                Task { @MainActor [weak self] in self?.openSelected(id) }
            }
            .store(in: &cancellables)
    }

    func startup() async {
        guard !started else { return }
        started = true
        coreVersion = RustCore.version()
        initCode = RustCore.initialize()
        if !isDemo {
            do {
                signedIn = try RustCore.status().signed_in
            } catch {
                signedIn = false
            }
        }
        await chats.load()
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
            feed.subscribe { [weak self] msg in
                Task { @MainActor [weak self] in self?.handleRealtime(msg) }
            }
            feed.onResync { [weak self] in
                Task { @MainActor [weak self] in self?.handleResync() }
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
    }

    /// Sign-in sheet state changed: signed in → status flip + list
    /// reload + dismiss; signed out → status flip (no dismiss — the
    /// user may sign straight back in).
    func authChanged(_ s: AuthState) {
        switch s {
        case .signedIn:
            signedIn = true
            chats.refresh()
            showSignIn = false
        case .signedOut:
            signedIn = false
        default:
            break
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                ChatListSidebar(model: state.chats)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
            } detail: {
                if state.openChatID == nil {
                    emptyDetail
                } else {
                    ConversationView(store: state.conv)
                }
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            // Shot hooks: open About/Auth windows from launch args.
            if CommandLine.arguments.contains("--show-about") {
                openWindow(id: AppIdentity.aboutWindowID)
            }
            if OstMacAppMain.authStateName(args: CommandLine.arguments) != nil {
                openWindow(id: AppIdentity.authWindowID)
            }
        }
        .task { await state.startup() }
        .onDisappear { state.shutdown() }
        .sheet(isPresented: $state.showSignIn) {
            AuthView(model: state.auth)
                .task { await state.auth.refreshStatus() }
                .onDisappear { state.auth.stopPolling() }
                .onChange(of: state.auth.state) { _, s in state.authChanged(s) }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Select a chat").font(.headline)
            if state.signedIn == false, !state.isDemo {
                Text("Not signed in — chats need sign-in.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Sign in…") { state.showSignIn = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text("core \(state.coreVersion) · init=\(state.initCode)")
                .font(.caption).monospaced().foregroundStyle(.secondary)
            if state.isDemo {
                Text("DEMO · offline")
                    .font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .clipShape(Capsule())
            } else {
                Text(state.signedIn.map { $0 ? "signed in" : "signed out" } ?? "auth ?")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(feedColor).frame(width: 8, height: 8)
                    Text(feedText).font(.caption).monospaced()
                }
                if let err = state.feedError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                if state.signedIn == false {
                    Button("Sign in…") { state.showSignIn = true }
                        .font(.caption)
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
