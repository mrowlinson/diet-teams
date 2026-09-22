// OstMac — integrated app: sidebar chat list + conversation detail +
// live realtime feed in one window.
//
// Usage:
//   OstMac [--demo] [--chat <id> [--name <n>]] [--say <text>]
// --demo runs fully offline (canned chats/messages, local send echo).
// --chat preselects (or opens directly when absent from the list).
// --say auto-sends once into the open chat. In live mode that is a REAL
// send via core — never use it on shared chats for testing.
//
// Realtime routing: the Trouter socket is global (one feed for all
// chats), so switching chats does NOT restart the socket — the app
// filters events to the open chat (`isFor(chatID:)`). A resync gap
// re-fetches the open chat plus the list.
import Combine
import Foundation
import OstMacChatList
import OstMacCore
import SwiftUI

@main
struct OstMacApp: App {
    @StateObject private var state: AppState

    init() {
        _state = StateObject(wrappedValue: AppState(args: CommandLine.arguments))
    }

    var body: some Scene {
        WindowGroup("OstMac") {
            RootView()
                .environmentObject(state)
        }
        .defaultSize(width: 1000, height: 640)
    }
}

@MainActor
final class AppState: ObservableObject {
    let isDemo: Bool
    let chats: ChatListViewModel
    let conv = ConversationStore()
    let feed = RealtimeFeed()
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
        isDemo = args.contains("--demo")
        if let i = args.firstIndex(of: "--chat"), i + 1 < args.count {
            preselectID = args[i + 1]
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
            chats = ChatListViewModel(fetcher: { _ in try DemoData.chatsResponse() })
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
            conv.showDemo(chatID: id, chatName: name, messages: DemoData.messages(for: id))
        } else {
            conv.open(chatID: id, chatName: chatName)
        }
    }

    /// One live event: count it, route to the open chat only.
    private func handleRealtime(_ msg: RealtimeMessage) {
        feedEvents += 1
        refreshFeedStatus()
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
}

struct RootView: View {
    @EnvironmentObject private var state: AppState

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
        .task { await state.startup() }
        .onDisappear { state.shutdown() }
        .sheet(isPresented: $state.showSignIn) {
            SignInView()
                .environmentObject(state)
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

struct SignInView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var uri = ""
    @State private var code = ""
    @State private var message = ""
    @State private var error: String?
    @State private var polling = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in").font(.headline)
            if uri.isEmpty {
                Text("Start a device-code flow, then approve in your browser.")
                    .font(.callout).foregroundStyle(.secondary)
                if let e = error {
                    Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                Button("Start sign-in") { start() }
            } else {
                Text("Visit:").font(.caption).foregroundStyle(.secondary)
                Text(uri).font(.body).monospaced().textSelection(.enabled)
                Text("Code: \(code)").font(.title2).monospaced().textSelection(.enabled)
                if !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if polling {
                    ProgressView("Waiting for approval…").controlSize(.small)
                }
                if let e = error {
                    Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                Button("Cancel") { cancel() }
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        error = nil
        do {
            let d = try RustCore.deviceStart()
            uri = d.verification_uri
            code = d.user_code
            message = d.message
            polling = true
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(max(d.interval, 5)))
                    if Task.isCancelled { break }
                    let done = await MainActor.run { pollOnce(session: d.session) }
                    if done { break }
                }
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    /// One poll; true = stop polling.
    private func pollOnce(session: String) -> Bool {
        do {
            let p = try RustCore.devicePoll(session: session)
            if p.status == "complete" {
                polling = false
                MainActor.assumeIsolated {
                    state.signedIn = true
                    state.chats.refresh()
                }
                dismiss()
                return true
            }
            return false
        } catch {
            self.error = String(describing: error)
            return false
        }
    }

    private func cancel() {
        pollTask?.cancel()
        pollTask = nil
        polling = false
        dismiss()
    }
}
