// InCallView.swift — om-call-ux: the in-call window (mute, camera
// on/off, speaker select, hang up). Native macOS Form throughout:
// Switch toggles, a Menu picker, Diet buttons. All controls bind the
// shared CallStore; camera capture runs on a window-owned session.
//
// Lifecycle: the window installs CallStore.cameraHook on appear so the
// store toggle drives capture; leaving the active phase (hang up,
// remote end) stops capture via the same path. Closing the window
// mid-call leaves call audio running — reopen to adjust.
import DietDesign
import SwiftUI

/// System Settings deep link to the Camera privacy row.
private let cameraPrivacyURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

public struct InCallView: View {
    @ObservedObject public var call: CallStore
    @StateObject private var camera = CameraCapture()
    @State private var cameras = CameraCapture.videoDevices()
    @State private var cameraDenied = false
    @Environment(\.openURL) private var openURL

    public init(call: CallStore) {
        self.call = call
    }

    public var body: some View {
        Form {
            Section("Call") {
                if let c = call.call, call.phase == .inviting || call.phase == .active {
                    LabeledContent("With", value: c.displayPeer)
                    LabeledContent("State", value: stateText(c))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent(
                            "Elapsed",
                            value: elapsedText(c, at: context.date))
                    }
                    if c.liveMedia == true {
                        LabeledContent(
                            "Media",
                            value: call.media.map(mediaLine) ?? "starting…")
                            .font(DietType.captionMono)
                    } else {
                        Text("Signaling only — mic/camera send once the call goes live.")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                } else {
                    Text(call.phase == .ended ? "Call ended." : "No active call.")
                        .foregroundStyle(DietColor.textSecondaryColor)
                    if call.phase == .ended {
                        Button("Clear") { call.clearEnded() }
                            .buttonStyle(.dietSecondary)
                    }
                }
            }
            Section("Audio") {
                Toggle("Mute microphone", isOn: muteBinding)
                    .toggleStyle(.switch)
                    .help("Mutes the live-call mic (stored when no call is live)")
                Picker("Speaker", selection: speakerBinding) {
                    Text("System Default").tag(String?.none)
                    ForEach(call.speakerDevices, id: \.self) { d in
                        Text(d).tag(String?.some(d))
                    }
                    if let sel = call.speaker,
                        call.speakersLoaded,
                        !call.speakerDevices.contains(sel)
                    {
                        Text("Previous speaker (unplugged)").tag(String?.some(sel))
                    }
                }
                .pickerStyle(.menu)
                .help("Switches live call audio now; stored for the next call when idle")
                HStack {
                    Button("Rescan speakers") { call.refreshSpeakers() }
                        .buttonStyle(.dietSecondary)
                    if let route = call.media?.speaker, !route.isEmpty {
                        Text("Route: \(route)")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    } else if call.media?.running == true {
                        Text("Route: system default")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                }
                if let se = call.media?.speakerError, !se.isEmpty {
                    Text(se)
                        .font(DietType.caption1)
                        .foregroundStyle(Color(nsColor: DietColor.danger))
                }
            }
            Section("Camera") {
                Toggle("Camera on", isOn: cameraBinding)
                    .toggleStyle(.switch)
                    .help("Starts/stops local capture (sends on a live call)")
                Picker("Camera", selection: $camera.selectedDeviceID) {
                    Text("System Default").tag(String?.none)
                    ForEach(cameras) { c in
                        Text(c.name).tag(String?.some(c.id))
                    }
                    if let sel = camera.selectedDeviceID,
                        !cameras.contains(where: { $0.id == sel })
                    {
                        Text("Previous camera (unplugged)").tag(String?.some(sel))
                    }
                }
                .pickerStyle(.menu)
                if camera.running {
                    CameraPreviewView(session: camera.session)
                        .frame(width: 240, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
                } else if call.cameraOn {
                    Text(camera.status)
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                if cameraDenied {
                    VStack(alignment: .leading, spacing: DietSpace.xs) {
                        Text("Camera access is off.")
                            .font(DietType.callout).bold()
                            .foregroundStyle(DietColor.textPrimaryColor)
                        Text("Allow Diet Teams in System Settings › Privacy & Security › Camera.")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                        Button("Open Privacy Settings", systemImage: "arrow.up.forward.app") {
                            openURL(cameraPrivacyURL)
                        }
                        .buttonStyle(.dietSecondary)
                    }
                }
            }
            if let err = call.controlsError {
                Section {
                    DietBanner(.error, message: err) { call.dismissControlsError() }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Hang Up", systemImage: "phone.down.fill") { hangUp() }
                        .buttonStyle(.dietDestructive)
                        .disabled(call.phase != .active && call.phase != .inviting)
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380)
        .navigationTitle("Call")
        .onAppear {
            call.refreshSpeakers()
            call.cameraHook = { [weak camera] on in
                Task { @MainActor [weak camera] in
                    guard let camera else { return }
                    await applyCamera(on, camera: camera)
                }
            }
            // Reopening with the toggle on restarts capture.
            if call.cameraOn { call.cameraHook?(true) }
        }
        .onDisappear {
            call.cameraHook = nil
            // Window closed after the call: stop capture. Mid-call it
            // keeps running (reopen to adjust).
            if call.phase != .active, call.phase != .inviting {
                camera.setLiveSend(false)
                camera.stop()
            }
        }
        .onChange(of: call.phase) { _, next in
            // Leaving the call stops capture via the store path.
            if next != .active, next != .inviting, call.cameraOn {
                call.setCameraOn(false)
            }
        }
        .onChange(of: call.call?.liveMedia ?? false) { _, live in
            camera.setLiveSend(live && call.cameraOn && camera.running)
        }
    }

    private var muteBinding: Binding<Bool> {
        Binding(get: { call.muted }, set: { call.setMuted($0) })
    }

    private var cameraBinding: Binding<Bool> {
        Binding(get: { call.cameraOn }, set: { call.setCameraOn($0) })
    }

    private var speakerBinding: Binding<String?> {
        Binding(get: { call.speaker }, set: { call.setSpeaker($0) })
    }

    private func hangUp() {
        if call.cameraOn { call.setCameraOn(false) }
        call.end()
    }

    @MainActor
    private func applyCamera(_ on: Bool, camera: CameraCapture) async {
        if on {
            cameraDenied = false
            guard await CameraCapture.requestAccess() else {
                cameraDenied = true
                call.setCameraOn(false)
                return
            }
            cameras = CameraCapture.videoDevices()
            camera.setLiveSend((call.call?.liveMedia ?? false) && call.cameraOn)
            camera.start()
        } else {
            camera.setLiveSend(false)
            camera.stop()
        }
    }

    private func stateText(_ c: CallInfo) -> String {
        switch (c.dir, c.state) {
        case ("in", "ringing"): "Ringing (incoming)"
        case ("out", "placing"): "Placing…"
        case (_, "connected"): c.liveMedia == true ? "Connected (live)" : "Connected"
        default: c.state
        }
    }

    private func elapsedText(_ c: CallInfo, at now: Date) -> String {
        guard c.startedAt > 0 else {
            return c.state == "ringing" ? "Ringing…" : "—"
        }
        let secs = max(0, Int(now.timeIntervalSince1970) - Int(c.startedAt))
        if c.state == "ringing" || c.state == "placing" {
            return "Ringing \(secs)s (auto-dismiss at \(Int(CallRingPolicy.timeoutSecs))s)"
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private func mediaLine(_ m: LiveMediaStats) -> String {
        if let e = m.error, !e.isEmpty { return "error: \(e)" }
        var s = "a \(m.audio_recv)/\(m.audio_sent) v \(m.video_recv)/\(m.video_sent)"
        if m.muted == true { s += " · muted" }
        return s
    }
}
