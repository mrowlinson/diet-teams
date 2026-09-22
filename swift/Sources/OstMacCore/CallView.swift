// CallView.swift — om-signal: signaling-only call controls.
//
// CallStore owns the core call slot (place/echo/accept/end/inject via
// Task.detached, like ConversationStore); CallBanner renders the active
// call; ConversationView's header gets a phone button bound to the open
// chat. No audio/video: accept/place wire signaling only, and the
// banner says so.
import SwiftUI

public final class CallStore: ObservableObject {
    @Published public private(set) var call: CallInfo?
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?
    @Published public private(set) var lastAction = ""
    private var generation = 0
    private let demo: Bool

    public init(demo: Bool = false) {
        self.demo = demo
    }

    public var isDemo: Bool { demo }

    /// Feed hook: a call event landed — re-read the slot.
    public func ingest(_ event: CallEvent) {
        lastAction = "event:\(event.kind)"
        refresh()
    }

    public func refresh() {
        if demo { return } // demo state is seeded, never re-read
        Task {
            let fetched: CallInfo?
            do {
                fetched = try await Task.detached { try RustCore.callStatus().call }.value
            } catch {
                fetched = nil
            }
            await MainActor.run { self.call = fetched }
        }
    }

    /// Seed offline demo state (shot hook: --show-call incoming|active).
    public func seedDemo(state: String) {
        switch state {
        case "incoming":
            call = CallInfo(
                id: "demo-call", dir: "in", peer: "8:orgid:demo",
                peerName: "Doe, Jane", thread: "", state: "ringing",
                detail: "modalities: Audio")
        case "active":
            call = CallInfo(
                id: "demo-call", dir: "out", peer: "8:orgid:demo",
                peerName: "Doe, Jane", thread: "19:demo@thread.v2",
                state: "connected", controller: "https://demo/conv/x",
                startedAt: 1, detail: "outgoing leg · ● Rec injects recorder")
        default:
            call = nil
        }
    }

    private func run(_ label: String, _ work: @escaping () throws -> CallResult) {
        if demo {
            // Offline echo: flip local state so the banner is exercisable.
            lastAction = "demo:\(label)"
            switch label {
            case "accept", "place", "echo":
                if var c = call { c = CallInfo(id: c.id, dir: c.dir, peer: c.peer, peerName: c.peerName, thread: c.thread, state: "connected", controller: c.controller, startedAt: c.startedAt, detail: c.detail); call = c }
                else { call = CallInfo(id: "demo-call", dir: "out", peer: "", peerName: "Doe, Jane", state: "connected") }
            case "end":
                call = nil
            default:
                break
            }
            return
        }
        busy = true
        error = nil
        generation += 1
        let gen = generation
        Task {
            let result: Result<CallResult, Error>
            do {
                result = try .success(await Task.detached { try work() }.value)
            } catch {
                result = .failure(error)
            }
            guard gen == generation else { return } // superseded
            busy = false
            switch result {
            case let .success(r):
                lastAction = label
                if let c = r.call { call = c } else { refresh() }
                if let rej = r.rejection, r.accepted == false { error = rej }
            case let .failure(e):
                error = String(describing: e)
                refresh()
            }
        }
    }

    public func place(threadID: String, timeoutSecs: Int32 = 30) {
        run("place") { try RustCore.callPlace(threadID: threadID, timeoutSecs: timeoutSecs) }
    }

    public func echo(timeoutSecs: Int32 = 30) {
        run("echo") { try RustCore.callEcho(timeoutSecs: timeoutSecs) }
    }

    public func accept() {
        run("accept") { try RustCore.callAccept() }
    }

    public func end() {
        run("end") { try RustCore.callEnd() }
    }

    public func injectRecorder() {
        run("record") { try RustCore.callRecordInject() }
    }

    public func dismissError() { error = nil }
}

/// Active-call banner: incoming accept/decline, outgoing progress,
/// connected end/record. Hidden when no call is active.
public struct CallBanner: View {
    @ObservedObject public var store: CallStore

    public init(store: CallStore) {
        self.store = store
    }

    public var body: some View {
        if let c = store.call, c.isActive {
            HStack(spacing: 10) {
                Image(systemName: icon(for: c))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(for: c)).font(.subheadline).bold()
                    Text(subtitle(for: c))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                buttons(for: c)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.green.opacity(0.12))
            Divider()
        } else if let err = store.error {
            HStack {
                Image(systemName: "phone.down.fill").foregroundStyle(.red)
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                Spacer()
                Button("Dismiss") { store.dismissError() }.font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.08))
            Divider()
        }
    }

    private func icon(for c: CallInfo) -> String {
        switch c.state {
        case "ringing": c.dir == "in" ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill"
        case "connected": "phone.fill"
        default: "phone"
        }
    }

    private func title(for c: CallInfo) -> String {
        switch (c.dir, c.state) {
        case ("in", "ringing"): "Incoming call from \(c.displayPeer)"
        case ("out", "placing"): "Calling \(c.displayPeer)…"
        case (_, "connected"): "In call · \(c.displayPeer)"
        case (_, "ringing"): "Ringing \(c.displayPeer)…"
        default: c.displayPeer
        }
    }

    private func subtitle(for c: CallInfo) -> String {
        let base = "signaling only — no audio yet"
        guard let d = c.detail, !d.isEmpty else { return base }
        if d.contains("signaling only") { return d } // seeded/echo detail
        return "\(base) · \(d)"
    }

    @ViewBuilder
    private func buttons(for c: CallInfo) -> some View {
        if c.dir == "in", c.state == "ringing" {
            Button("Accept") { store.accept() }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy)
            Button("Decline") { store.end() }
                .buttonStyle(.bordered)
                .disabled(store.busy)
        } else {
            if c.state == "connected", c.dir == "out" {
                Button("● Rec") { store.injectRecorder() }
                    .buttonStyle(.bordered)
                    .disabled(store.busy)
                    .help("Inject the recorder bot (signaling only)")
            }
            Button("End") { store.end() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(store.busy)
        }
    }
}
