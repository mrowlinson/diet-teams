// CallView.swift — om-signal: signaling-only call controls.
//
// CallStore owns the core call slot (place/echo/accept/end/inject via
// Task.detached, like ConversationStore); CallBanner renders the active
// call; ConversationView's header gets a phone button bound to the open
// chat. No audio/video: accept/place wire signaling only, and the
// banner says so.
// om-reskin-call: DietDesign banner (tokens + button styles;
// error row is a DietBanner).
import DietDesign
import SwiftUI

public final class CallStore: ObservableObject {
    @Published public private(set) var call: CallInfo?
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?
    @Published public private(set) var lastAction = ""
    @Published public private(set) var media: LiveMediaStats?
    private var generation = 0
    private var mediaGeneration = 0
    private var mediaPolling = false
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
            await MainActor.run {
                self.call = fetched
                self.syncMediaPoll()
            }
        }
    }

    /// Run the 1s media-stats loop exactly while a live call is up.
    private func syncMediaPoll() {
        let live = call?.liveMedia == true && (call?.isActive ?? false)
        let polling = mediaPolling
        if live, !polling {
            mediaPolling = true
            mediaGeneration += 1
            let gen = mediaGeneration
            Task.detached(priority: .utility) { [weak self] in
                while self?.mediaPolling == true, self?.mediaGeneration == gen {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard self?.mediaPolling == true, self?.mediaGeneration == gen else { return }
                    do {
                        let m = try RustCore.callMedia().media
                        await MainActor.run { [weak self] in
                            guard let self, self.mediaGeneration == gen else { return }
                            self.media = m
                        }
                    } catch {
                        // Transient; next tick retries.
                    }
                }
            }
        } else if !live, polling {
            mediaPolling = false
            mediaGeneration += 1 // supersede any parked loop
            media = nil
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
        case "live":
            call = CallInfo(
                id: "demo-call", dir: "out", peer: "8:orgid:demo",
                peerName: "Doe, Jane", thread: "19:demo@thread.v2",
                state: "connected", controller: "https://demo/conv/x",
                startedAt: 1, detail: "echo bot · a/v flowing",
                liveMedia: true)
        default:
            call = nil
        }
    }

    private func run(_ label: String, _ work: @escaping () throws -> CallResult) {
        if demo {
            // Offline echo: flip local state so the banner is exercisable.
            lastAction = "demo:\(label)"
            switch label {
            case "accept", "place", "echo", "accept-live", "place-live", "echo-live":
                let live = label.hasSuffix("-live")
                if var c = call { c = CallInfo(id: c.id, dir: c.dir, peer: c.peer, peerName: c.peerName, thread: c.thread, state: "connected", controller: c.controller, startedAt: c.startedAt, detail: c.detail, liveMedia: live ? true : c.liveMedia); call = c }
                else { call = CallInfo(id: "demo-call", dir: "out", peer: "", peerName: "Doe, Jane", state: "connected", liveMedia: live ? true : nil) }
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
                if let c = r.call {
                    call = c
                    syncMediaPoll()
                } else { refresh() }
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

    public func placeLive(threadID: String, timeoutSecs: Int32 = 30) {
        run("place-live") { try RustCore.callPlaceLive(threadID: threadID, timeoutSecs: timeoutSecs) }
    }

    public func echo(timeoutSecs: Int32 = 30) {
        run("echo") { try RustCore.callEcho(timeoutSecs: timeoutSecs) }
    }

    public func echoLive(timeoutSecs: Int32 = 30) {
        run("echo-live") { try RustCore.callEchoLive(timeoutSecs: timeoutSecs) }
    }

    public func accept() {
        run("accept") { try RustCore.callAccept() }
    }

    public func acceptLive() {
        run("accept-live") { try RustCore.callAcceptLive() }
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
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                HStack(spacing: DietSpace.sm) {
                    Image(systemName: icon(for: c))
                        .font(.system(size: DietSize.iconMD))
                        .foregroundStyle(Color(nsColor: DietColor.success))
                    if c.liveMedia == true {
                        Text("LIVE")
                            .font(DietType.caption2).bold()
                            .padding(.horizontal, DietSpace.sm)
                            .padding(.vertical, DietSpace.xxs)
                            .background(
                                Color(nsColor: DietColor.danger).opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .accessibilityLabel("Live media active")
                    }
                    VStack(alignment: .leading, spacing: DietSpace.xxs) {
                        Text(title(for: c)).font(DietType.subheadline).bold()
                            .foregroundStyle(DietColor.textPrimaryColor)
                        Text(subtitle(for: c))
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                            .lineLimit(1)
                    }
                    Spacer()
                    if store.busy { ProgressView().controlSize(.small) }
                    buttons(for: c)
                }
                if c.liveMedia == true, let m = store.media {
                    Text(mediaLine(m))
                        .font(DietType.captionMono)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DietSpace.edgeCompact)
            .padding(.vertical, DietSpace.sm)
            .background(Color(nsColor: DietColor.success).opacity(0.12))
            DietDividerH()
        } else if let err = store.error {
            DietBanner(.error, message: err) { store.dismissError() }
                .padding(.horizontal, DietSpace.edgeCompact)
                .padding(.vertical, DietSpace.xs)
            DietDividerH()
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
        let base = c.liveMedia == true
            ? "live media — mic/camera send, speaker/video recv"
            : "signaling only — no audio yet"
        guard let d = c.detail, !d.isEmpty else { return base }
        if d.contains("signaling only") { return d } // seeded/echo detail
        return "\(base) · \(d)"
    }

    private func mediaLine(_ m: LiveMediaStats) -> String {
        if let e = m.error, !e.isEmpty { return "media error: \(e)" }
        return "a \(m.audio_recv)/\(m.audio_sent) v \(m.video_recv)/\(m.video_sent)" +
            " ice=\(m.ice_audio.isEmpty ? "…" : "ok")/\(m.ice_video.isEmpty ? "…" : "ok")" +
            " q=\(m.send_queued)/\(m.recv_pending)"
    }

    @ViewBuilder
    private func buttons(for c: CallInfo) -> some View {
        if c.dir == "in", c.state == "ringing" {
            Button("Accept live") { store.acceptLive() }
                .buttonStyle(.dietPrimary)
                .disabled(store.busy)
                .help("Accept with live audio/video")
            Button("Accept") { store.accept() }
                .buttonStyle(.dietSecondary)
                .disabled(store.busy)
                .help("Accept signaling only")
            Button("Decline") { store.end() }
                .buttonStyle(.dietDestructive)
                .disabled(store.busy)
        } else {
            if c.state == "connected", c.dir == "out" {
                Button("● Rec") { store.injectRecorder() }
                    .buttonStyle(.dietSecondary)
                    .disabled(store.busy)
                    .help("Inject the recorder bot (signaling only)")
            }
            Button("End") { store.end() }
                .buttonStyle(.dietDestructive)
                .disabled(store.busy)
        }
    }
}
