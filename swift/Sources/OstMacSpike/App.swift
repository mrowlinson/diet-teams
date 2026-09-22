// OstMacSpike — minimal SwiftUI shell proving the Rust core FFI.
import OstMacChatList
import OstMacCore
import SwiftUI

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup("OstMac Spike") { ContentView() }
            .defaultSize(width: 900, height: 560)
    }
}

@MainActor
final class CoreLog: ObservableObject {
    @Published var lines: [String] = []
    func add(_ s: String) {
        lines.append(s)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
}

struct ContentView: View {
    @StateObject private var log = CoreLog()
    @StateObject private var chats = ChatListViewModel()
    @StateObject private var auth = AuthViewModel()
    @State private var authShown = false
    @State private var coreVersion = "?"
    @State private var initCode: Int32 = -99
    @State private var signedIn: Bool?
    @State private var deviceSession: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var trouterOn = false
    @State private var trouterTimer: Timer?

    var body: some View {
        NavigationSplitView {
            ChatListSidebar(model: chats)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                Text("OstMac spike — Rust core + SwiftUI")
                    .font(.headline)
                Text("core \(coreVersion) · init=\(initCode) · signed_in=\(signedIn.map(String.init) ?? "?")")
                    .font(.caption).monospaced()
                Text("selected chat: \(chats.selectedChatID ?? "none")")
                    .font(.caption).monospaced().foregroundStyle(.secondary)
                HStack {
                    Button("Status") { refreshStatus() }
                    Button("Device start") { deviceStart() }
                    Button("Poll once") { pollOnce() }
                    Button("Chats") { fetchChats() }
                }
                HStack {
                    Button(trouterOn ? "Trouter stop" : "Trouter start") { toggleTrouter() }
                    Button("Account…") { authShown = true }
                    Button("Clear log") { log.lines = [] }
                }
                if let s = deviceSession {
                    Text("session: \(s)").font(.caption).monospaced()
                        .textSelection(.enabled)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(log.lines.indices, id: \.self) { i in
                            Text(log.lines[i]).font(.caption).monospaced()
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 480)
        .sheet(isPresented: $authShown) {
            VStack {
                AuthView(model: auth)
                Button("Close") { authShown = false }
                    .padding(.bottom)
            }
            .task { await auth.refreshStatus() }
        }
        .onAppear {
            coreVersion = RustCore.version()
            initCode = RustCore.initialize()
            log.add("init=\(initCode) version=\(coreVersion)")
            refreshStatus()
            Task { await chats.load() }
        }
        .onDisappear { stopPolling() }
    }

    func refreshStatus() {
        do {
            let st = try RustCore.status()
            signedIn = st.signed_in
            log.add("status signed_in=\(st.signed_in) skype=\(st.tokens.skype.present)/exp=\(st.tokens.skype.expired)")
        } catch { log.add("status ERR \(error)") }
    }

    func deviceStart() {
        do {
            let d = try RustCore.deviceStart()
            deviceSession = d.session
            log.add("device session=\(d.session)")
            log.add("visit \(d.verification_uri) code \(d.user_code)")
            startPolling(session: d.session, interval: d.interval)
        } catch { log.add("device ERR \(error)") }
    }

    func pollOnce() {
        guard let s = deviceSession else { log.add("poll: no session"); return }
        do {
            let p = try RustCore.devicePoll(session: s)
            log.add("poll \(p.status)")
            if p.status == "complete" { deviceSession = nil; refreshStatus() }
        } catch { log.add("poll ERR \(error)") }
    }

    func startPolling(session: String, interval: Int) {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(interval, 5)))
                if Task.isCancelled { break }
                await MainActor.run { pollOnce() }
                if deviceSession == nil { break }
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    func fetchChats() {
        do {
            let r = try RustCore.chats()
            log.add("chats n=\(r.chats.count)")
            for c in r.chats.prefix(5) { log.add("  \(c.name) [\(c.chatId)]") }
        } catch { log.add("chats ERR \(error)") }
    }

    func toggleTrouter() {
        if trouterOn {
            let rc = RustCore.trouterStop()
            log.add("trouter stop rc=\(rc)")
            trouterTimer?.invalidate(); trouterTimer = nil
            trouterOn = false
        } else {
            let rc = RustCore.trouterStart()
            log.add("trouter start rc=\(rc) (0 ok, -1 running, -2 no auth)")
            if rc == 0 {
                trouterOn = true
                trouterTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    Task { @MainActor in
                        do {
                            let p = try RustCore.trouterPoll()
                            for e in p.events { log.add("event \(e.value.prefix(300))") }
                        } catch { log.add("trouter poll ERR \(error)") }
                    }
                }
            }
        }
    }
}
