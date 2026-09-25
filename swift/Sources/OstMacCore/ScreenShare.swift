// ScreenShare.swift — om-screenshare: screen sharing in calls via ScreenCaptureKit.
// Session model + permission states are pure (unit-tested, no live capture);
// ScreenShareModel owns the SCContentSharingPicker + SCStream engine, the
// local preview tile, and the live-send path into the call (VT-encode +
// RustCore.videoSendPush, mirroring CameraCapture). Counters stay in the
// Diagnostics window — the tile shows status words only.
import CoreGraphics
import CoreMedia
import DietDesign
import ScreenCaptureKit
import SwiftUI
import VideoToolbox

// MARK: - Permission (pure states + TCC gate)

/// Screen Recording authorization. Tri-state: unknown until probed
/// (headless/CI stays unknown — preflight never prompts, never hangs).
/// Denied is set only on failure evidence (stream start refused while
/// preflight is false), never from preflight alone — preflight cannot
/// tell not-yet-asked from denied.
public enum ScreenSharePermission: Equatable, Sendable {
    case unknown
    case authorized
    case denied

    /// Pure mapping from a preflight probe (nil = unprobed).
    public init(granted: Bool?) {
        switch granted {
        case .some(true): self = .authorized
        case .some(false): self = .denied
        case .none: self = .unknown
        }
    }

    public var isDenied: Bool { self == .denied }
    public var isAuthorized: Bool { self == .authorized }
}

/// Screen Recording TCC gate (mirrors MicAccess; status reads never prompt).
/// The system picker owns the one authorization prompt — there is no
/// separate request call; post-denial recovery is the Settings deep link.
public enum ScreenShareAccess {
    /// Prompt-free preflight (false headless/denied — never hangs).
    public static func granted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Current permission (never prompts).
    public static func status() -> ScreenSharePermission {
        ScreenSharePermission(granted: granted())
    }

    /// System Settings deep link to the Screen Recording privacy row.
    public static let privacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

// MARK: - Session model (pure, unit-tested)

/// What the user picked in the system picker. The SCContentFilter itself
/// is engine-owned (SCKit types never enter the pure model).
public struct ScreenShareSource: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case display
        case window
        case app
    }

    public let id: String
    public let kind: Kind
    /// Human size tag from the picked content rect (e.g. "1920×1080").
    public let name: String

    public init(id: String, kind: Kind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

/// Share lifecycle. Failed keeps its detail in `lastError`, like CallStore.
public enum ScreenSharePhase: Equatable, Sendable {
    case idle
    /// System picker on screen, awaiting the user's choice.
    case picking
    /// Stream create/add-output/start in flight.
    case starting
    case live
    case stopping
    case failed

    public var isLive: Bool { self == .live }
    public var isBusy: Bool {
        self == .picking || self == .starting || self == .stopping
    }
}

/// Pure session state machine: transitions only, no ScreenCaptureKit.
/// The engine (ScreenShareModel) drives these from picker/stream callbacks.
public struct ScreenShareSession: Equatable, Sendable {
    public private(set) var phase: ScreenSharePhase = .idle
    public private(set) var source: ScreenShareSource?
    public private(set) var lastError: String?

    public init() {}

    /// User tapped Share: the picker opens. False unless idle/failed (retry).
    @discardableResult
    public mutating func beginPick() -> Bool {
        guard phase == .idle || phase == .failed else { return false }
        phase = .picking
        lastError = nil
        return true
    }

    /// Picker delivered a choice: stream bring-up starts. False unless picking
    /// (stray re-picks while live are ignored — stop, then re-share).
    @discardableResult
    public mutating func didPick(_ source: ScreenShareSource) -> Bool {
        guard phase == .picking else { return false }
        self.source = source
        phase = .starting
        return true
    }

    /// Picker dismissed with no choice: back to idle (keeps the prior source).
    public mutating func didCancelPick() {
        guard phase == .picking else { return }
        phase = .idle
    }

    /// Stream started: live. False unless starting.
    @discardableResult
    public mutating func didStart() -> Bool {
        guard phase == .starting else { return false }
        phase = .live
        lastError = nil
        return true
    }

    /// Anything failed: failed + detail. No-op when idle.
    public mutating func didFail(_ detail: String) {
        guard phase != .idle else { return }
        phase = .failed
        lastError = detail
    }

    /// User tapped Stop: teardown starts. False unless live/starting
    /// (a stop mid-bring-up is honored when the start lands).
    @discardableResult
    public mutating func beginStop() -> Bool {
        guard phase == .live || phase == .starting else { return false }
        phase = .stopping
        return true
    }

    /// Stream stopped: idle, source kept for one-tap re-share. False unless
    /// stopping.
    @discardableResult
    public mutating func didStop() -> Bool {
        guard phase == .stopping else { return false }
        phase = .idle
        lastError = nil
        return true
    }
}

// MARK: - Pure summaries (unit-tested)

public enum ScreenShareSummary {
    /// Phase -> one human word (failures keep their detail). No numbers —
    /// counters live in Diagnostics only.
    public static func status(phase: ScreenSharePhase, lastError: String?) -> String {
        switch phase {
        case .idle: return "Off"
        case .picking: return "Choose a screen…"
        case .starting: return "Starting…"
        case .live: return "Live"
        case .stopping: return "Stopping…"
        case .failed:
            guard let lastError, !lastError.isEmpty else { return "Failed" }
            return "Failed — \(lastError)"
        }
    }

    /// Source -> one-line label.
    public static func label(for source: ScreenShareSource) -> String {
        switch source.kind {
        case .display: return "Display · \(source.name)"
        case .window: return "Window · \(source.name)"
        case .app: return "App · \(source.name)"
        }
    }

    /// Denied-permission hint (mirrors AvSummary.micDenied).
    public static let denied =
        "Screen Recording denied — allow Better Teams in System Settings › Privacy & Security › Screen Recording"
}

// MARK: - Model + engine

/// ScreenCaptureKit owner: system picker -> SCStream -> preview + live send.
/// Main-actor published state; picker/stream callbacks hop from wherever
/// SCK invokes them. Never starts capture unless the user taps Share.
@MainActor
public final class ScreenShareModel: NSObject, ObservableObject {
    @Published public private(set) var session = ScreenShareSession()
    @Published public private(set) var permission: ScreenSharePermission = .unknown
    @Published public private(set) var preview: CGImage?
    /// Counters for Diagnostics only (never rendered in the tile).
    @Published public private(set) var framesCaptured = 0
    @Published public private(set) var framesSent = 0
    /// Live-send path (mirrors CameraCapture): VT-encode each frame and
    /// push NALs to the Rust send queue while a live call is up.
    @Published public private(set) var liveSend = false

    public var phase: ScreenSharePhase { session.phase }
    public var sourceLabel: String? {
        session.source.map(ScreenShareSummary.label)
    }

    private var stream: SCStream?
    private var sink: ShareFrameSink?
    private let queue = DispatchQueue(label: "dev.ostmac.screenshare")
    /// Queue-confined live-send state (mirrors CameraCapture's boxes).
    private nonisolated let liveBox = ShareEncoderBox()
    private nonisolated let liveFlag = ShareLiveFlag()

    override public init() {
        super.init()
        // --share-denied shot hook: seed + hold the denial state.
        if CommandLine.arguments.contains("--share-denied") {
            permission = .denied
        }
    }

    /// Refresh the cached permission (prompt-free; call on appear and
    /// after Settings trips). Preflight true recovers to authorized;
    /// false never sets denied by itself (see ScreenSharePermission).
    public func refreshPermission() {
        if ScreenShareAccess.granted() {
            permission = .authorized
        } else if permission == .authorized {
            permission = .unknown // revoked externally; next failure re-marks
        }
    }

    /// Enable/disable live-send encoding into the call's send queue.
    public func setLiveSend(_ on: Bool) {
        liveSend = on
        liveFlag.set(on)
        if !on { liveBox.reset() }
    }

    /// Share: refresh permission, then present the system source picker.
    /// Denial stays in-state with the Settings hint (never a bare error);
    /// the picker owns the first-run authorization prompt.
    public func start() {
        refreshPermission()
        guard permission != .denied else { return }
        guard session.beginPick() else { return }
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        picker.defaultConfiguration = config
        picker.isActive = true
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.present()
    }

    /// Stop sharing (live, or mid-bring-up — honored when the start lands).
    public func stop() {
        guard session.beginStop() else { return }
        guard let stream else {
            // Bring-up never built a stream (or already torn down).
            setLiveSend(false)
            sink = nil
            _ = session.didStop()
            return
        }
        Task {
            try? await stream.stopCapture()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.setLiveSend(false)
                self.stream = nil
                self.sink = nil
                _ = self.session.didStop()
            }
        }
    }

    // MARK: Picker results (main-actor; observer methods hop here)

    private func adoptPicked(filter: SCContentFilter) {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        guard session.didPick(Self.describe(filter: filter)) else { return }
        let sink = ShareFrameSink(owner: self, box: liveBox, flag: liveFlag)
        self.sink = sink
        Task { await bringUp(filter: filter, sink: sink) }
    }

    private func notePickCancelled() {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        session.didCancelPick()
    }

    private func notePickerFailed(_ error: Error) {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        if !ScreenShareAccess.granted() {
            permission = .denied
            session.didFail("permission denied")
        } else {
            session.didFail(error.localizedDescription)
        }
    }

    // MARK: Stream bring-up / teardown (main-actor)

    private func bringUp(filter: SCContentFilter, sink: ShareFrameSink) async {
        let config = SCStreamConfiguration()
        config.width = 960
        config.height = 600
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.queueDepth = 4
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            noteStartFailed(error)
            return
        }
        if session.phase == .starting {
            self.stream = stream
            _ = session.didStart()
        } else {
            // Stopped mid-bring-up: tear the just-started stream down.
            try? await stream.stopCapture()
            setLiveSend(false)
            self.sink = nil
            _ = session.didStop()
        }
    }

    private func noteStartFailed(_ error: Error) {
        setLiveSend(false)
        sink = nil
        if !ScreenShareAccess.granted() {
            permission = .denied
            session.didFail("permission denied")
        } else {
            session.didFail(error.localizedDescription)
        }
    }

    /// Stream died on its own (source closed, system interrupted): fail
    /// unless we are already stopping (expected) or idle (late callback).
    private func noteStreamDied(_ error: Error) {
        guard session.phase == .live else { return }
        setLiveSend(false)
        stream = nil
        sink = nil
        session.didFail("stream ended")
    }

    /// One publish tick: the latest preview + exact coalesced counters.
    fileprivate func noteFrame(image: CGImage, captured: Int, sent: Int) {
        preview = image
        framesCaptured += captured
        framesSent += sent
    }

    /// Filter -> pure source descriptor (style + content-rect size; SCK
    /// exposes no display/window names on the macOS 14 floor).
    static func describe(filter: SCContentFilter) -> ScreenShareSource {
        let kind: ScreenShareSource.Kind
        if filter.style == .window {
            kind = .window
        } else if filter.style == .application {
            kind = .app
        } else {
            kind = .display
        }
        let rect = filter.contentRect
        let dims = "\(Int(rect.width))×\(Int(rect.height))"
        return ScreenShareSource(id: "\(kind.rawValue)-\(dims)", kind: kind, name: dims)
    }
}

// MARK: - SCK callbacks (hop to main; never block the SCK queues)

extension ScreenShareModel: SCContentSharingPickerObserver {
    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in self?.notePickCancelled() }
    }

    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in self?.adoptPicked(filter: filter) }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.notePickerFailed(error) }
    }
}

extension ScreenShareModel: SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.noteStreamDied(error) }
    }
}

// MARK: - Frame sink (sample queue)

/// Preview-publish gate: the first frame publishes immediately, then at
/// most every 250ms (4Hz). Counters stay exact — the sink coalesces the
/// frames between ticks. Pure (unit-tested).
public enum SharePreviewGate {
    public static let minIntervalMs: UInt64 = 250

    public static func shouldPublish(nowMs: UInt64, lastMs: UInt64?) -> Bool {
        guard let lastMs else { return true }
        return nowMs &- lastMs >= minIntervalMs
    }

    static func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

/// Queue-side SCK output: complete frames -> preview CGImage + optional
/// VT-encode + send-queue push. Publish hops to main via the weak owner.
private final class ShareFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private weak var owner: ScreenShareModel?
    private let box: ShareEncoderBox
    private let flag: ShareLiveFlag
    /// Publish coalescing (sample queue only — the queue is serial).
    private var lastPublishMs: UInt64?
    private var pendingCaptured = 0
    private var pendingSent = 0

    init(owner: ScreenShareModel, box: ShareEncoderBox, flag: ShareLiveFlag) {
        self.owner = owner
        self.box = box
        self.flag = flag
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[SCStreamFrameInfo.status] as? Int,
            SCFrameStatus(rawValue: raw) == .complete,
            let pixels = sampleBuffer.imageBuffer
        else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) == noErr,
              let image
        else { return }
        var sent = false
        if flag.get() {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else {
                note(image: image, sent: false)
                return
            }
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            var packed = Data(count: width * height * 4)
            packed.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let dest = dst.baseAddress!
                for row in 0 ..< height {
                    memcpy(dest + row * width * 4, base + row * stride, width * 4)
                }
            }
            do {
                let nals = try box.encode(bgra: packed, width: width, height: height)
                _ = try RustCore.videoSendPush(nals: nals)
                sent = true
            } catch {
                // Transient: the frame still previews, the next one retries
                // (the engine falls back to black IDR when idle).
            }
        }
        note(image: image, sent: sent)
    }

    /// Count every frame; publish the latest preview at most 4Hz.
    private func note(image: CGImage, sent: Bool) {
        pendingCaptured += 1
        if sent { pendingSent += 1 }
        let now = SharePreviewGate.nowMs()
        guard SharePreviewGate.shouldPublish(nowMs: now, lastMs: lastPublishMs) else {
            return
        }
        lastPublishMs = now
        let captured = pendingCaptured
        let sentCount = pendingSent
        pendingCaptured = 0
        pendingSent = 0
        publish(image: image, captured: captured, sent: sentCount)
    }

    private func publish(image: CGImage, captured: Int, sent: Int) {
        Task { @MainActor [weak owner = self.owner] in
            owner?.noteFrame(image: image, captured: captured, sent: sent)
        }
    }
}

/// NSLock-guarded live-send flag (sample-queue use from a @MainActor class).
private final class ShareLiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }; value = on
    }
    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Queue-confined stream encoder: created lazily at first live frame,
/// recreated when capture dims change. Encode runs off the lock.
private final class ShareEncoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var encoder: H264StreamEncoder?
    private var dims = (0, 0)

    func encode(bgra: Data, width: Int, height: Int) throws -> [Data] {
        lock.lock()
        if encoder == nil || dims != (width, height) {
            encoder = H264StreamEncoder(width: width, height: height)
            dims = (width, height)
        }
        let enc = encoder
        lock.unlock()
        guard let enc else { throw H264EncodeError.session(-1) }
        return try enc.encode(bgra: bgra)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        encoder = nil
        dims = (0, 0)
    }
}

// MARK: - Tile

/// Local screen-share tile: preview + status word + Share/Stop + the
/// denied-permission path. No numeric counters (Diagnostics only).
public struct ScreenShareTile: View {
    @ObservedObject public var model: ScreenShareModel
    /// True while a live-media call is up (enables the send toggle).
    public var liveCall: Bool
    @Environment(\.openURL) private var openURL

    public init(model: ScreenShareModel, liveCall: Bool) {
        self.model = model
        self.liveCall = liveCall
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if model.phase.isLive, let img = model.preview {
                    Image(img, scale: 1, label: Text("Screen share preview"))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: DietSpace.xs) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: DietSize.iconLG))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(ScreenShareSummary.status(
                            phase: model.phase,
                            lastError: model.session.lastError))
                            .font(DietType.caption1)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if model.phase.isLive {
                    VStack {
                        HStack {
                            Spacer()
                            Text("SHARING")
                                .font(DietType.caption2).bold()
                                .padding(.horizontal, DietSpace.sm)
                                .padding(.vertical, DietSpace.xxs)
                                .background(Color(nsColor: DietColor.danger).opacity(0.85))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                                .accessibilityLabel("Screen sharing live")
                        }
                        Spacer()
                    }
                    .padding(DietSpace.sm)
                }
            }
            .frame(width: 320, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .stroke(DietColor.dividerColor))
            Text(sourceLine)
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .lineLimit(1)
            HStack(spacing: DietSpace.sm) {
                if model.phase.isLive {
                    Button("Stop Share", systemImage: "stop.fill", role: .destructive) {
                        model.stop()
                    }
                    .buttonStyle(.bordered)
                    if liveCall {
                        Toggle(
                            "Send to call",
                            isOn: Binding(
                                get: { model.liveSend },
                                set: { model.setLiveSend($0) }))
                            .font(DietType.callout)
                            .help("Encode shared frames into the live call")
                    }
                } else {
                    Button("Share Screen…", systemImage: "rectangle.on.rectangle") {
                        model.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase.isBusy)
                    .help("Pick a display, window, or app to share")
                }
            }
            if model.permission.isDenied {
                VStack(alignment: .leading, spacing: DietSpace.xs) {
                    Text("Screen Recording is off — sharing needs it.")
                        .font(DietType.callout).bold()
                        .foregroundStyle(DietColor.textPrimaryColor)
                    Text("Allow Better Teams in System Settings › Privacy & Security › Screen Recording.")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Button("Open Privacy Settings", systemImage: "arrow.up.forward.app") {
                        openURL(ScreenShareAccess.privacyURL)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen share")
    }

    private var sourceLine: String {
        if let label = model.sourceLabel {
            return model.phase.isLive ? label : "Last: \(label) — Share to pick again"
        }
        return "Pick a display, window, or app to share"
    }
}
