// AvPanelView.swift — om-av-polish: Call A/V setup (mic/speaker/camera).
// Human surface: real device names, test buttons with progress/success,
// live mic level. All core internals (caps, probe, echo, dry-run, VT
// round-trip, loopback) live behind the collapsed Diagnostics disclosure.
// Blocking core calls run via Task.detached; state publishes on-main.
// om-reskin-call: DietDesign cards (section cards, button styles,
// type/space/color tokens; same model, same actions).
// om-avfix: mic TCC gate (one .audio prompt on Test; probe/meter wait
// for the grant; denial hint + Settings link), unknown_device
// rescan+heal (empty-list wedge keeps the pick, true unplug heals to
// the default). om-av-fix: open_failed (resolved but unusable) shows a
// retry line and never heals the pick.
import DietDesign
import SwiftUI

// MARK: - Pure helpers (unit-tested)

/// Test-button lifecycle.
public enum TestPhase: Equatable, Sendable {
    case idle
    case running
    case done
    case failed

    public var isRunning: Bool { self == .running }
}

/// dBFS -> meter fraction.
public enum AvLevel {
    /// Map dBFS (-60..0) onto 0..1, clamped. -50 dB and below reads empty.
    public static func fraction(db: Double) -> Double {
        min(1, max(0, (db + 50) / 50))
    }
}

/// Terse, numbers-first result strings. No key=value in the main view.
public enum AvSummary {
    public static func micTest(_ r: MicTestResult) -> String {
        String(format: "%.1fs · peak %.0fdB · %@", r.seconds, r.peak_db,
            r.played_back ? "played back" : "no playback")
    }

    public static func tone(frames: Int, msecs: Int) -> String {
        String(format: "%.1fs · %d frames", Double(msecs) / 1000, frames)
    }

    public static func cameraStats(_ s: CameraStats) -> String {
        String(format: "%d frames · %.1f fps · %d dropped",
            s.frames, s.fps_actual, s.dropped)
    }

    /// Raw camera status -> one human word (failures keep their detail).
    public static func cameraStatus(_ raw: String) -> String {
        switch raw {
        case "idle", "stopped": return "Off"
        case "starting…": return "Starting…"
        case "capturing": return "Live"
        case "stopping…": return "Stopping…"
        default: break
        }
        if let rest = rest(after: "failed: ", in: raw) { return "Failed — \(rest)" }
        if let rest = rest(after: "push failed: ", in: raw) { return "Push failed — \(rest)" }
        return raw
    }

    /// Core error -> human line. Unknown shapes pass through untouched.
    public static func friendlyError(_ e: Error) -> String {
        guard case let CoreCallError.failed(m) = e else { return e.localizedDescription }
        if m.contains("unknown_device") { return "Device unplugged — pick another" }
        if m.contains("open_failed") { return "Couldn't open device — try again" }
        if m.contains("no_input") { return "Microphone unavailable" }
        if m.contains("no_output") { return "Speaker unavailable" }
        return m
    }

    /// True when a core error is a stale device pick (unknown_device).
    /// open_failed is NOT unknown: the pick resolved, the stream failed —
    /// the panel must not heal it away.
    public static func isUnknownDevice(_ e: Error) -> Bool {
        guard case let CoreCallError.failed(m) = e else { return false }
        return m.contains("unknown_device")
    }

    /// Mic TCC denial -> human line + where to fix it.
    public static let micDenied =
        "Microphone denied — allow Better Teams in System Settings › Privacy & Security › Microphone"

    /// True-unplug heal: the pick is gone, the panel switched to the default.
    public static func healedMic(_ fallback: String?) -> String {
        "Device unplugged — switched to \(fallback ?? "System Default")"
    }

    public static func healedSpeaker(_ fallback: String?) -> String {
        "Device unplugged — switched to \(fallback ?? "System Default")"
    }

    /// Empty-list wedge: the rescan found nothing (HAL wedge, not a true
    /// unplug) — the pick is kept, Rescan retries.
    public static func wedgeKept(_ pick: String?) -> String {
        "No devices found — kept \(pick ?? "selection") (Rescan to retry)"
    }

    /// The stale pick is back in the fresh list (transient error).
    public static let deviceBack = "Device available again — retry the test"

    /// Probe placeholder until the Test-owned mic grant lands.
    public static let probePending = "pending mic access"

    private static func rest(after prefix: String, in s: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }
}

/// Stale-pick heal decision after a rescan (unit-tested).
public enum AvHeal {
    public enum Action: Equatable, Sendable {
        case valid // pick present in the fresh list (transient error)
        case wedge // fresh list empty (HAL wedge) — keep the pick
        case unplugged // fresh list non-empty, pick missing — heal to default
    }

    public static func action(pick: String?, devices: [String]) -> Action {
        guard let pick, !pick.isEmpty else { return .valid }
        if devices.contains(pick) { return .valid }
        return devices.isEmpty ? .wedge : .unplugged
    }
}

// MARK: - Model

@MainActor
public final class AvPanelModel: ObservableObject {
    // Devices (real names; picks persisted).
    @Published public var micDevices: [String] = []
    @Published public var speakerDevices: [String] = []
    @Published public var devicesLoaded = false
    @Published public var micDevice: String? {
        didSet { UserDefaults.standard.set(micDevice, forKey: Self.micKey) }
    }
    @Published public var speakerDevice: String? {
        didSet { UserDefaults.standard.set(speakerDevice, forKey: Self.speakerKey) }
    }
    public static let micKey = "om.av.micDevice"
    public static let speakerKey = "om.av.speakerDevice"

    // Test state.
    @Published public var micPhase = TestPhase.idle
    @Published public var micResult = "Not tested"
    @Published public var speakerPhase = TestPhase.idle
    @Published public var speakerResult = "Not tested"

    // Live level (0..1). levelLive=false = no input right now.
    @Published public var level = 0.0
    @Published public var levelLive = false

    // Mic TCC denial: the panel shows the fix-it hint until granted.
    @Published public var micDenied = false
    /// --av-mic-denied shot hook: seed + hold the denial state.
    private let denyPreview: Bool
    /// unknown_device follow-up: which pick the rescan must heal.
    private enum HealKind { case mic, speaker }
    private var pendingHeal: HealKind?

    // Diagnostics (collapsed by default; raw core output lives here).
    @Published public var diagExpanded = false
    @Published public var caps = "—"
    @Published public var probe = "—"
    @Published public var check = "idle"
    @Published public var dry = "idle"
    @Published public var decode = "idle"
    @Published public var remoteImage: CGImage?
    @Published public var decodedImage: CGImage?
    @Published public var loop = "idle"

    private var levelTimer: Timer?
    private var levelSampling = false

    public init() {
        micDevice = UserDefaults.standard.string(forKey: Self.micKey)
        speakerDevice = UserDefaults.standard.string(forKey: Self.speakerKey)
        denyPreview = CommandLine.arguments.contains("--av-mic-denied")
        if denyPreview {
            micDenied = true
            micPhase = .failed
            micResult = AvSummary.micDenied
        }
    }

    /// Off-main runner: `work` runs detached, `apply` publishes on-main.
    private func run<T: Sendable>(
        _ apply: @escaping @MainActor (Result<T, Error>) -> Void,
        work: @escaping @Sendable () throws -> T
    ) {
        Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try work()) } catch { result = .failure(error) }
            await MainActor.run {
                apply(result)
            }
        }
    }

    // MARK: Devices

    public func refreshDevices() {
        run({ [weak self] (r: Result<AudioDevices, Error>) in
            guard let self else { return }
            switch r {
            case let .success(d):
                self.micDevices = d.inputs
                self.speakerDevices = d.outputs
                // Adopt the system default only when the user never picked.
                if self.micDevice == nil { self.micDevice = d.default_input }
                if self.speakerDevice == nil { self.speakerDevice = d.default_output }
                self.drainHeal(devices: d)
            case .failure:
                self.micDevices = []
                self.speakerDevices = []
                self.drainHeal(devices: nil)
            }
            self.devicesLoaded = true
            // Chained after enumeration so CoreAudio setup never contends
            // with the device scan (concurrent probes wedge some drivers).
            self.refreshProbe()
            self.startLevelPolling()
        }, work: { try RustCore.audioDevices() })
    }

    /// unknown_device follow-up: the rescan just landed — heal a true
    /// unplug to the system default, keep the pick on a wedge/empty list.
    private func drainHeal(devices d: AudioDevices?) {
        guard let kind = pendingHeal else { return }
        pendingHeal = nil
        switch kind {
        case .mic:
            micPhase = .failed
            switch AvHeal.action(pick: micDevice, devices: d?.inputs ?? []) {
            case .valid:
                micResult = AvSummary.deviceBack
            case .wedge:
                micResult = AvSummary.wedgeKept(micDevice)
            case .unplugged:
                micDevice = d?.default_input
                micResult = AvSummary.healedMic(d?.default_input)
            }
        case .speaker:
            speakerPhase = .failed
            switch AvHeal.action(pick: speakerDevice, devices: d?.outputs ?? []) {
            case .valid:
                speakerResult = AvSummary.deviceBack
            case .wedge:
                speakerResult = AvSummary.wedgeKept(speakerDevice)
            case .unplugged:
                speakerDevice = d?.default_output
                speakerResult = AvSummary.healedSpeaker(d?.default_output)
            }
        }
    }

    /// Unplug/replug recovery: stop the meter, rescan, restart it.
    public func rescanDevices() {
        stopLevelPolling()
        devicesLoaded = false
        refreshDevices()
    }

    // MARK: Live level

    public func startLevelPolling() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollLevel() }
        }
    }

    public func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func pollLevel() {
        // Meter waits for the device scan, then yields to the mic test
        // (it owns the input stream while recording); resumes after.
        guard devicesLoaded, !levelSampling, micPhase != .running else { return }
        // TCC gate (prompt-free): denial flats the meter + raises the panel
        // hint; not-determined idles — the Test button owns the one prompt.
        if MicAccess.denied {
            micDenied = true
            levelLive = false
            level = 0
            return
        }
        guard MicAccess.status() == .authorized else {
            levelLive = false
            level = 0
            return
        }
        if !denyPreview { micDenied = false }
        levelSampling = true
        let input = micDevice
        run({ [weak self] (r: Result<MicLevel, Error>) in
            guard let self else { return }
            self.levelSampling = false
            switch r {
            case let .success(v):
                self.levelLive = v.has_input
                self.level = v.has_input ? AvLevel.fraction(db: v.peak_db) : 0
            case .failure:
                self.levelLive = false
                self.level = 0
            }
        }, work: { try RustCore.micLevel(msecs: 150, input: input) })
    }

    // MARK: Tests (routed to the picked devices)

    public func runMicTest() {
        guard micPhase != .running else { return }
        micPhase = .running
        micResult = "Requesting microphone…"
        // The one mic prompt (mirrors startCamera): denial lands in the
        // panel with the Settings hint instead of a core no_input error.
        Task {
            guard await MicAccess.requestAccess() else {
                micDenied = true
                micPhase = .failed
                micResult = AvSummary.micDenied
                return
            }
            micDenied = false
            micResult = "Recording 3s…"
            let input = micDevice
            let output = speakerDevice
            run({ [weak self] (r: Result<MicTestResult, Error>) in
                guard let self else { return }
                switch r {
                case let .success(v):
                    self.micPhase = .done
                    self.micResult = AvSummary.micTest(v)
                case let .failure(e):
                    if AvSummary.isUnknownDevice(e), self.pendingHeal == nil {
                        self.pendingHeal = .mic
                        self.micResult = "Rescanning devices…"
                        self.rescanDevices()
                    } else {
                        self.micPhase = .failed
                        self.micResult = AvSummary.friendlyError(e)
                    }
                }
            }, work: { try RustCore.micTestOn(seconds: 3, input: input, output: output) })
        }
    }

    public func runTonePlay() {
        guard speakerPhase != .running else { return }
        speakerPhase = .running
        speakerResult = "Playing 1s…"
        let output = speakerDevice
        run({ [weak self] (r: Result<TonePlayResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.speakerPhase = .done
                self.speakerResult = AvSummary.tone(frames: v.frames, msecs: 1000)
            case let .failure(e):
                if AvSummary.isUnknownDevice(e), self.pendingHeal == nil {
                    self.pendingHeal = .speaker
                    self.speakerResult = "Rescanning devices…"
                    self.rescanDevices()
                } else {
                    self.speakerPhase = .failed
                    self.speakerResult = AvSummary.friendlyError(e)
                }
            }
        }, work: { try RustCore.tonePlayOn(msecs: 1000, output: output) })
    }

    // MARK: Diagnostics (unchanged behavior, raw output)

    public func refreshCaps() {
        run({ [weak self] (r: Result<AvInfo, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.caps = "mic=\(v.mic) cam=\(v.camera) disp=\(v.display) pkt=\(v.packetizer)"
            case let .failure(e):
                self.caps = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.avInfo() })
    }

    public func refreshProbe() {
        // The probe opens the input stream (a TCC prompt on fresh
        // machines), so it waits for the Test-owned grant like the meter.
        guard MicAccess.status() == .authorized else {
            probe = AvSummary.probePending
            return
        }
        run({ [weak self] (r: Result<MicProbe, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.probe = "input=\(v.input ? "yes" : "no") output=\(v.output ? "yes" : "no")"
            case let .failure(e):
                self.probe = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.micProbe() })
    }

    public func runToneCheck() {
        run({ [weak self] (r: Result<ToneCheckResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.check = String(
                    format: "echo=%@ delay=%.0fms corr=%.2f",
                    v.detected ? "yes" : "no", v.delay_ms, v.correlation_peak)
            case let .failure(e):
                self.check = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.toneCheck() })
    }

    public func runDryRun() {
        run({ [weak self] (r: Result<DryRunResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.dry = "a \(v.audio_received)/\(v.audio_sent) echo=\(v.echo_detected ? "yes" : "no")" +
                    " v pkts=\(v.video_packets) nals=\(v.video_nals)"
            case let .failure(e):
                self.dry = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.callDryRun() })
    }

    /// Native round-trip: encode a marker frame, decode it back, show it.
    public func runRoundTrip() {
        decode = "encoding…"
        run({ [weak self] (r: Result<CGImage, Error>) in
            guard let self else { return }
            switch r {
            case let .success(img):
                self.decodedImage = img
                self.decode = "\(img.width)x\(img.height) VT round-trip"
            case let .failure(e):
                self.decode = "failed: \(e.localizedDescription)"
            }
        }, work: {
            let w = 320, h = 240
            var bgra = Data(repeating: 64, count: w * h * 4)
            bgra.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let p = dst.baseAddress!
                for row in 0 ..< h / 2 {
                    for col in 0 ..< w / 2 {
                        let o = (row * w + col) * 4
                        p.storeBytes(of: UInt8(220), toByteOffset: o, as: UInt8.self)
                        p.storeBytes(of: UInt8(220), toByteOffset: o + 1, as: UInt8.self)
                        p.storeBytes(of: UInt8(220), toByteOffset: o + 2, as: UInt8.self)
                    }
                }
            }
            let (sps, pps, slices) = try H264Encode.encode(
                bgra: bgra, width: w, height: h)
            var nals = [sps, pps]
            nals.append(contentsOf: slices)
            return try H264Decode.decode(nals: nals)
        })
    }

    /// Full join check (offline): VT-encode a marker frame, push the NALs,
    /// run the engine packetize/SRTP/depacketize path, decode the AU back.
    public func runLiveLoopback() {
        loop = "encoding…"
        run({ [weak self] (r: Result<CGImage, Error>) in
            guard let self else { return }
            switch r {
            case let .success(img):
                self.remoteImage = img
                self.loop = "\(img.width)x\(img.height) live loopback"
            case let .failure(e):
                self.loop = "failed: \(e.localizedDescription)"
            }
        }, work: {
            let w = 320, h = 240
            var bgra = Data(repeating: 64, count: w * h * 4)
            bgra.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let p = dst.baseAddress!
                for row in 0 ..< h / 2 {
                    for col in 0 ..< w / 2 {
                        let o = (row * w + col) * 4
                        p.storeBytes(of: UInt8(40), toByteOffset: o, as: UInt8.self)
                        p.storeBytes(of: UInt8(120), toByteOffset: o + 1, as: UInt8.self)
                        p.storeBytes(of: UInt8(220), toByteOffset: o + 2, as: UInt8.self)
                    }
                }
            }
            guard let enc = H264StreamEncoder(width: w, height: h) else {
                throw CoreCallError.failed("no VT encoder")
            }
            let nals = try enc.encode(bgra: bgra)
            _ = try RustCore.videoSendPush(nals: nals)
            let lb = try RustCore.liveLoopback()
            guard lb.aus >= 1 else {
                throw CoreCallError.failed("loopback produced no AU")
            }
            let poll = try RustCore.videoPollIncoming()
            guard let au = poll.au else {
                throw CoreCallError.failed("incoming queue empty")
            }
            guard let img = try H264StreamDecoder().decode(nals: au.nals) else {
                throw CoreCallError.failed("no slice NALs in AU")
            }
            return img
        })
    }

    /// Round-trip a synthetic I420 frame through the remote slot and show it.
    public func runRemoteLoopback() {
        run({ [weak self] (r: Result<CGImage, Error>) in
            guard let self else { return }
            switch r {
            case let .success(img):
                self.remoteImage = img
                self.decode = "\(img.width)x\(img.height) remote-slot loopback"
            case let .failure(e):
                self.decode = "failed: \(e.localizedDescription)"
            }
        }, work: {
            // 64x64 mid-gray I420 with a bright quadrant marker.
            let w = 64, h = 64
            var y = Data(repeating: 128, count: w * h)
            for row in 0 ..< h / 2 {
                for col in 0 ..< w / 2 { y[row * w + col] = 220 }
            }
            var i420 = y
            i420.append(Data(repeating: 128, count: w * h / 4))
            i420.append(Data(repeating: 128, count: w * h / 4))
            try RustCore.videoPushRemote(i420: i420, width: w, height: h)
            let poll = try RustCore.videoPollRemote()
            guard let f = poll.frame,
                  let img = YUVConvert.cgImage(i420: f.data, width: f.width, height: f.height)
            else {
                throw CoreCallError.failed("remote loopback empty")
            }
            return img
        })
    }
}

// MARK: - Views

/// Horizontal input-level meter (0..1). Gray when no input.
public struct LevelBar: View {
    public var fraction: Double
    public var live: Bool

    public init(fraction: Double, live: Bool) {
        self.fraction = fraction
        self.live = live
    }

    public var body: some View {
        // Empty label views: hosted inside LabeledContent at both call
        // sites, so the Gauge must not print its own title or value
        // (.labelsHidden leaves linearCapacity labels stacked on macOS).
        // VoiceOver keeps the meter semantics via explicit traits.
        Gauge(value: live ? min(1, max(0, fraction)) : 0, in: 0...1) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .gaugeStyle(.linearCapacity)
        .accessibilityLabel("Input level")
        .accessibilityValue(live ? "\(Int(fraction * 100)) percent" : "no input")
    }
}

public struct AvPanelView: View {
    @StateObject private var model = AvPanelModel()
    @StateObject private var camera = CameraCapture()
    @StateObject private var call = CallStore()
    @StateObject private var share: ScreenShareModel
    @State private var cameras = CameraCapture.videoDevices()
    @Environment(\.openURL) private var openURL

    /// The app injects its shared model (Diagnostics reads the same
    /// counters); standalone use falls back to a private one.
    public init(screenShare: ScreenShareModel? = nil) {
        _share = StateObject(wrappedValue: screenShare ?? ScreenShareModel())
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DietSpace.section) {
                DietSectionCard("Microphone", systemImage: "mic.fill") {
                    VStack(alignment: .leading, spacing: DietSpace.sm) {
                        devicePicker("Microphone", devices: model.micDevices,
                            selection: $model.micDevice,
                            loaded: model.devicesLoaded,
                            empty: "No microphone found")
                        HStack(spacing: DietSpace.sm) {
                            Button("Test Microphone", systemImage: "mic") {
                                model.runMicTest()
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.micPhase.isRunning)
                            phaseStatus(model.micPhase, model.micResult)
                        }
                        if model.micDenied {
                            VStack(
                                alignment: .leading,
                                spacing: DietSpace.xs
                            ) {
                                Text("Microphone access is off — the test and level meter need it.")
                                    .font(DietType.callout).bold()
                                    .foregroundStyle(DietColor.textPrimaryColor)
                                Text("Allow Better Teams in System Settings › Privacy & Security › Microphone.")
                                    .font(DietType.caption1)
                                    .foregroundStyle(
                                        DietColor.textSecondaryColor)
                                Button(
                                    "Open Privacy Settings",
                                    systemImage: "arrow.up.forward.app"
                                ) {
                                    openURL(MicAccess.privacyURL)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        LabeledContent("Input level") {
                            LevelBar(
                                fraction: model.level,
                                live: model.levelLive)
                                .frame(maxWidth: 220)
                        }
                        .font(DietType.callout)
                        Text("3s record, then playback.")
                            .font(DietType.caption1)
                            .foregroundStyle(
                                DietColor.textSecondaryColor)
                    }
                }

                DietSectionCard(
                    "Speaker", systemImage: "speaker.wave.2.fill"
                ) {
                    VStack(alignment: .leading, spacing: DietSpace.sm) {
                        devicePicker("Speaker",
                            devices: model.speakerDevices,
                            selection: $model.speakerDevice,
                            loaded: model.devicesLoaded,
                            empty: "No speaker found")
                        HStack(spacing: DietSpace.sm) {
                            Button(
                                "Play Test Sound",
                                systemImage: "speaker.wave.2"
                            ) {
                                model.runTonePlay()
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.speakerPhase.isRunning)
                            phaseStatus(
                                model.speakerPhase, model.speakerResult)
                        }
                    }
                }

                DietSectionCard("Camera", systemImage: "video.fill") {
                    VStack(alignment: .leading, spacing: DietSpace.sm) {
                        Picker("Camera",
                            selection: $camera.selectedDeviceID)
                        {
                            Text("System Default").tag(String?.none)
                            ForEach(cameras) { c in
                                Text(c.name).tag(String?.some(c.id))
                            }
                            if let sel = camera.selectedDeviceID,
                                !cameras.contains(where: { $0.id == sel })
                            {
                                Text("Previous camera (unplugged)")
                                    .tag(String?.some(sel))
                            }
                        }
                        .font(DietType.callout)
                        HStack(alignment: .top, spacing: DietSpace.sm) {
                            if camera.running {
                                CameraPreviewView(session: camera.session)
                                    .frame(width: 240, height: 180)
                                    .clipShape(RoundedRectangle(
                                        cornerRadius: DietRadius.control))
                                    .overlay(RoundedRectangle(
                                        cornerRadius: DietRadius.control
                                    ).stroke(DietColor.dividerColor))
                            } else {
                                RoundedRectangle(
                                    cornerRadius: DietRadius.control)
                                    .fill(DietColor.wellColor)
                                    .frame(width: 240, height: 180)
                                    .overlay {
                                        VStack(spacing: DietSpace.xs) {
                                            Image(systemName: "video.slash")
                                                .font(.system(size: DietSize
                                                    .iconLG))
                                                .foregroundStyle(DietColor
                                                    .textSecondaryColor)
                                            Text("Camera off")
                                                .font(DietType.callout)
                                                .foregroundStyle(DietColor
                                                    .textSecondaryColor)
                                        }
                                    }
                            }
                            VStack(
                                alignment: .leading,
                                spacing: DietSpace.sm
                            ) {
                                Text(AvSummary.cameraStatus(
                                    camera.status))
                                    .font(DietType.callout).bold()
                                    .foregroundStyle(DietColor
                                        .textPrimaryColor)
                                if let s = camera.lastStats {
                                    Text(AvSummary.cameraStats(s))
                                        .font(DietType.caption1)
                                        .foregroundStyle(DietColor
                                            .textSecondaryColor)
                                }
                                Button(
                                    camera.running ? "Stop" : "Start",
                                    systemImage: camera.running
                                        ? "stop.fill" : "play.fill"
                                ) {
                                    if camera.running { camera.stop() } else {
                                        startCamera()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, DietSpace.xxs)
                        }
                    }
                }

                DietSectionCard(
                    "Screen share", systemImage: "rectangle.on.rectangle"
                ) {
                    ScreenShareTile(
                        model: share,
                        liveCall: call.call?.liveMedia == true
                            && (call.call?.isActive ?? false))
                }

                DietSectionCard(
                    "Diagnostics", systemImage: "stethoscope"
                ) {
                    DisclosureGroup(isExpanded: $model.diagExpanded) {
                        VStack(
                            alignment: .leading,
                            spacing: DietSpace.sm
                        ) {
                            HStack(spacing: DietSpace.sm) {
                                Button("Probe") {
                                    model.refreshCaps()
                                    model.refreshProbe()
                                }
                                .buttonStyle(.bordered)
                                Button("Rescan Devices") {
                                    model.rescanDevices()
                                    cameras = CameraCapture
                                        .videoDevices()
                                }
                                .buttonStyle(.bordered)
                            }
                            diagRow("core", model.caps)
                            diagRow("devices", model.probe)
                            HStack(spacing: DietSpace.sm) {
                                Button("Echo check") {
                                    model.runToneCheck()
                                }
                                .buttonStyle(.bordered)
                                Text(model.check)
                                    .font(DietType.caption1)
                                    .foregroundStyle(DietColor
                                        .textSecondaryColor)
                            }
                            HStack(spacing: DietSpace.sm) {
                                Button("Dry run") {
                                    model.runDryRun()
                                }
                                .buttonStyle(.bordered)
                                Text(model.dry)
                                    .font(DietType.caption1)
                                    .foregroundStyle(DietColor
                                        .textSecondaryColor)
                            }
                            HStack(spacing: DietSpace.sm) {
                                Button("VT round-trip") {
                                    model.runRoundTrip()
                                }
                                .buttonStyle(.bordered)
                                Button("Remote loopback") {
                                    model.runRemoteLoopback()
                                }
                                .buttonStyle(.bordered)
                                Text(model.decode)
                                    .font(DietType.caption1)
                                    .foregroundStyle(DietColor
                                        .textSecondaryColor)
                            }
                            HStack(spacing: DietSpace.sm) {
                                Button("Live loopback") {
                                    model.runLiveLoopback()
                                }
                                .buttonStyle(.bordered)
                                Text(model.loop)
                                    .font(DietType.caption1)
                                    .foregroundStyle(DietColor
                                        .textSecondaryColor)
                            }
                            HStack(
                                alignment: .top,
                                spacing: DietSpace.md
                            ) {
                                if let img = model.decodedImage {
                                    Image(
                                        img, scale: 1,
                                        label: Text("decoded")
                                    )
                                    .resizable()
                                    .frame(width: 176, height: 144)
                                    .clipShape(RoundedRectangle(
                                        cornerRadius: DietRadius
                                            .control))
                                }
                                if let img = model.remoteImage {
                                    Image(
                                        img, scale: 1,
                                        label: Text("remote")
                                    )
                                    .resizable()
                                    .frame(width: 128, height: 128)
                                    .clipShape(RoundedRectangle(
                                        cornerRadius: DietRadius
                                            .control))
                                }
                            }
                        }
                        .padding(.top, DietSpace.xs)
                    } label: {
                        Text("Core internals")
                            .font(DietType.callout)
                            .foregroundStyle(
                                DietColor.textSecondaryColor)
                    }
                }

                DietSectionCard(
                    "Live call (echo bot + media)",
                    systemImage: "phone.fill"
                ) {
                    VStack(
                        alignment: .leading,
                        spacing: DietSpace.sm
                    ) {
                        CallBanner(store: call)
                        HStack(spacing: DietSpace.sm) {
                            Button("Echo live") { call.echoLive() }
                                .buttonStyle(.borderedProminent)
                                .disabled(call.busy
                                    || (call.call?.isActive ?? false))
                            Button("End", role: .destructive) { call.end() }
                                .buttonStyle(.bordered)
                                .disabled(call.busy
                                    || !(call.call?.isActive ?? false))
                            if let m = call.media {
                                Text("a \(m.audio_recv)/\(m.audio_sent)" +
                                    " v \(m.video_recv)/\(m.video_sent)")
                                    .font(DietType.captionMono)
                                    .foregroundStyle(DietColor
                                        .textSecondaryColor)
                            }
                        }
                        HStack(
                            alignment: .top,
                            spacing: DietSpace.md
                        ) {
                            LiveVideoView()
                            VStack(
                                alignment: .leading,
                                spacing: DietSpace.sm
                            ) {
                                Text("local send: \(camera.liveSend ? "on" : "off")")
                                    .font(DietType.caption1)
                                    .foregroundStyle(DietColor
                                        .textSecondaryColor)
                                Button(
                                    camera.liveSend ? "Stop send"
                                        : "Send camera"
                                ) {
                                    if camera.liveSend {
                                        camera.setLiveSend(false)
                                    } else if camera.running {
                                        camera.setLiveSend(true)
                                    } else {
                                        startCamera(live: true)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .padding(DietSpace.edge)
        }
        .background(DietColor.windowColor)
        .frame(minWidth: 560, minHeight: 700)
        .task {
            // Devices first; probe + level meter chain after the scan.
            model.refreshDevices()
            model.refreshCaps()
            call.refresh()
            share.refreshPermission()
            // Shot hook: --auto-loop runs the live loopback at launch.
            if CommandLine.arguments.contains("--auto-loop") {
                model.runLiveLoopback()
            }
        }
        .onAppear {
            call.callWindowOpen = true // media surface up (1s stats loop)
        }
        .onDisappear {
            call.callWindowOpen = false // media surface down
            model.stopLevelPolling()
            camera.stop()
            share.stop()
        }
    }

    /// Audio device picker with real names. Stale picks stay visible as unplugged.
    private func devicePicker(
        _ label: String, devices: [String],
        selection: Binding<String?>, loaded: Bool, empty: String
    ) -> some View {
        Group {
            if !loaded {
                LabeledContent(label) {
                    Text("Scanning…")
                        .foregroundStyle(
                            DietColor.textSecondaryColor)
                }
            } else if devices.isEmpty {
                LabeledContent(label) {
                    Text(empty)
                        .foregroundStyle(
                            DietColor.textSecondaryColor)
                }
            } else {
                Picker(label, selection: selection) {
                    ForEach(devices, id: \.self) { d in
                        Text(d).tag(String?.some(d))
                    }
                    if let sel = selection.wrappedValue,
                        !devices.contains(sel)
                    {
                        Text("\(sel) (unplugged)")
                            .tag(String?.some(sel))
                    }
                }
            }
        }
        .font(DietType.callout)
    }

    private func phaseStatus(_ phase: TestPhase, _ text: String) -> some View {
        HStack(spacing: DietSpace.xs) {
            switch phase {
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(DietColor.textSecondaryColor)
            case .running:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: DietColor.success))
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(nsColor: DietColor.danger))
            }
            Text(text).font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private func diagRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: DietSpace.sm) {
            Text(k).font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .frame(width: 60, alignment: .leading)
            Text(v).font(DietType.captionMono)
                .foregroundStyle(DietColor.textPrimaryColor)
                .textSelection(.enabled)
        }
    }

    private func startCamera(live: Bool = false) {
        Task {
            guard await CameraCapture.requestAccess() else { return }
            camera.start()
            if live { camera.setLiveSend(true) }
        }
    }
}
