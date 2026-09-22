// AvPanelView.swift — om-av-polish: Call A/V setup (mic/speaker/camera).
// Human surface: real device names, test buttons with progress/success,
// live mic level. All core internals (caps, probe, echo, dry-run, VT
// round-trip, loopback) live behind the collapsed Diagnostics disclosure.
// Blocking core calls run via Task.detached; state publishes on-main.
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
        if m.contains("no_input") { return "Microphone unavailable" }
        if m.contains("no_output") { return "Speaker unavailable" }
        return m
    }

    private static func rest(after prefix: String, in s: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
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
            case .failure:
                self.micDevices = []
                self.speakerDevices = []
            }
            self.devicesLoaded = true
            // Chained after enumeration so CoreAudio setup never contends
            // with the device scan (concurrent probes wedge some drivers).
            self.refreshProbe()
            self.startLevelPolling()
        }, work: { try RustCore.audioDevices() })
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
                self.micPhase = .failed
                self.micResult = AvSummary.friendlyError(e)
            }
        }, work: { try RustCore.micTestOn(seconds: 3, input: input, output: output) })
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
                self.speakerPhase = .failed
                self.speakerResult = AvSummary.friendlyError(e)
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
            let raw = au.nals.compactMap { Data(base64Encoded: $0) }
            guard raw.count == au.nals.count else {
                throw CoreCallError.failed("incoming NAL base64")
            }
            guard let img = try H264StreamDecoder().decode(nals: raw) else {
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
                  let raw = Data(base64Encoded: f.data),
                  let img = YUVConvert.cgImage(i420: raw, width: f.width, height: f.height)
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
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                if live, fraction > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.green.gradient)
                        .frame(width: g.size.width * min(1, fraction))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(live ? "\(Int(fraction * 100)) percent" : "no input")
    }
}

public struct AvPanelView: View {
    @StateObject private var model = AvPanelModel()
    @StateObject private var camera = CameraCapture()
    @StateObject private var call = CallStore()
    @State private var cameras = CameraCapture.videoDevices()

    public init() {}

    public var body: some View {
        Form {
            Section {
                devicePicker("Microphone", devices: model.micDevices,
                    selection: $model.micDevice, loaded: model.devicesLoaded,
                    empty: "No microphone found")
                HStack {
                    Button("Test Microphone", systemImage: "mic") { model.runMicTest() }
                        .disabled(model.micPhase.isRunning)
                    phaseStatus(model.micPhase, model.micResult)
                }
                LabeledContent("Input level") {
                    LevelBar(fraction: model.level, live: model.levelLive)
                        .frame(maxWidth: 220)
                }
            } header: {
                Label("Microphone", systemImage: "mic.fill")
            } footer: {
                Text("3s record, then playback.")
            }

            Section {
                devicePicker("Speaker", devices: model.speakerDevices,
                    selection: $model.speakerDevice, loaded: model.devicesLoaded,
                    empty: "No speaker found")
                HStack {
                    Button("Play Test Sound", systemImage: "speaker.wave.2") {
                        model.runTonePlay()
                    }
                    .disabled(model.speakerPhase.isRunning)
                    phaseStatus(model.speakerPhase, model.speakerResult)
                }
            } header: {
                Label("Speaker", systemImage: "speaker.wave.2.fill")
            }

            Section {
                Picker("Camera", selection: $camera.selectedDeviceID) {
                    Text("System Default").tag(String?.none)
                    ForEach(cameras) { c in
                        Text(c.name).tag(String?.some(c.id))
                    }
                    if let sel = camera.selectedDeviceID, !cameras.contains(where: { $0.id == sel }) {
                        Text("Previous camera (unplugged)").tag(String?.some(sel))
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    if camera.running {
                        CameraPreviewView(session: camera.session)
                            .frame(width: 240, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary.opacity(0.5))
                            .frame(width: 240, height: 180)
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "video.slash")
                                        .font(.title2).foregroundStyle(.secondary)
                                    Text("Camera off")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AvSummary.cameraStatus(camera.status))
                            .font(.callout).bold()
                        if let s = camera.lastStats {
                            Text(AvSummary.cameraStats(s))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(camera.running ? "Stop" : "Start",
                            systemImage: camera.running ? "stop.fill" : "play.fill")
                        {
                            if camera.running { camera.stop() } else { startCamera() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            } header: {
                Label("Camera", systemImage: "video.fill")
            }

            DisclosureGroup(isExpanded: $model.diagExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Probe") { model.refreshCaps(); model.refreshProbe() }
                        Button("Rescan Devices") {
                            model.rescanDevices()
                            cameras = CameraCapture.videoDevices()
                        }
                    }
                    diagRow("core", model.caps)
                    diagRow("devices", model.probe)
                    HStack {
                        Button("Echo check") { model.runToneCheck() }
                        Text(model.check).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Dry run") { model.runDryRun() }
                        Text(model.dry).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("VT round-trip") { model.runRoundTrip() }
                        Button("Remote loopback") { model.runRemoteLoopback() }
                        Text(model.decode).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Live loopback") { model.runLiveLoopback() }
                        Text(model.loop).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        if let img = model.decodedImage {
                            Image(img, scale: 1, label: Text("decoded"))
                                .resizable().frame(width: 176, height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let img = model.remoteImage {
                            Image(img, scale: 1, label: Text("remote"))
                                .resizable().frame(width: 128, height: 128)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Section {
                CallBanner(store: call)
                HStack {
                    Button("Echo live") { call.echoLive() }
                        .disabled(call.busy || (call.call?.isActive ?? false))
                    Button("End") { call.end() }
                        .disabled(call.busy || !(call.call?.isActive ?? false))
                    if let m = call.media {
                        Text("a \(m.audio_recv)/\(m.audio_sent)" +
                            " v \(m.video_recv)/\(m.video_sent)")
                            .font(.caption).monospaced().foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    LiveVideoView()
                    VStack(alignment: .leading) {
                        Text("local send: \(camera.liveSend ? "on" : "off")")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(camera.liveSend ? "Stop send" : "Send camera") {
                            if camera.liveSend {
                                camera.setLiveSend(false)
                            } else if camera.running {
                                camera.setLiveSend(true)
                            } else {
                                startCamera(live: true)
                            }
                        }
                    }
                }
            } header: {
                Label("Live call (echo bot + media)", systemImage: "phone.fill")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 700)
        .task {
            // Devices first; probe + level meter chain after the scan.
            model.refreshDevices()
            model.refreshCaps()
            call.refresh()
            // Shot hook: --auto-loop runs the live loopback at launch.
            if CommandLine.arguments.contains("--auto-loop") {
                model.runLiveLoopback()
            }
        }
        .onDisappear {
            model.stopLevelPolling()
            camera.stop()
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
                    Text("Scanning…").foregroundStyle(.secondary)
                }
            } else if devices.isEmpty {
                LabeledContent(label) {
                    Text(empty).foregroundStyle(.secondary)
                }
            } else {
                Picker(label, selection: selection) {
                    ForEach(devices, id: \.self) { d in
                        Text(d).tag(String?.some(d))
                    }
                    if let sel = selection.wrappedValue, !devices.contains(sel) {
                        Text("\(sel) (unplugged)").tag(String?.some(sel))
                    }
                }
            }
        }
    }

    private func phaseStatus(_ phase: TestPhase, _ text: String) -> some View {
        HStack(spacing: 6) {
            switch phase {
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            Text(text).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private func diagRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled)
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
