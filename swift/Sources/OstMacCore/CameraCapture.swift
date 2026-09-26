// CameraCapture.swift — om-av: native macOS camera via AVFoundation.
// Feeds BGRA frames to the Rust camera pump (I420 convert + stats) and
// exposes the session for a SwiftUI preview layer. No V4L2.
import AVFoundation
import AppKit
import SwiftUI

/// One built-in/external/Continuity camera, listed for the picker.
public struct CameraDevice: Identifiable, Hashable, Sendable {
    public let id: String // AVCaptureDevice.uniqueID (stable across launches)
    public let name: String // localizedName ("FaceTime HD Camera")
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// AVCapture owner: BGRA frame output -> RustCore.cameraPush. Main-actor
/// published state; delegate callbacks arrive on a private queue.
@MainActor
public final class CameraCapture: NSObject, ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var status = "idle"
    @Published public private(set) var lastStats: CameraStats?
    /// Selected camera uniqueID (nil = system default). Persisted.
    @Published public var selectedDeviceID: String? {
        didSet {
            UserDefaults.standard.set(selectedDeviceID, forKey: Self.deviceKey)
            if running, oldValue != selectedDeviceID { restart() }
        }
    }

    public static let deviceKey = "om.av.cameraDeviceID"

    public let session = AVCaptureSession()
    private var output: AVCaptureVideoDataOutput?
    private let queue = DispatchQueue(label: "dev.ostmac.camera")
    /// Push worker: the AVCapture callback only packs rows, then hands the
    /// buffer here so capture never waits on the core push or VT encode.
    private nonisolated let pushQueue = DispatchQueue(label: "dev.ostmac.camera-push")
    /// Touched from the delegate + push queues; locked for Sendable.
    private nonisolated let pushCount = LockedInt()
    /// Live-send path (om-liveav): VT-encode each frame and push NALs to the
    /// Rust send queue. Box is queue-confined; flag toggles from any thread.
    private nonisolated let liveBox = StreamEncoderBox()
    private nonisolated let liveFlag = LockedFlag()
    /// Reusable pack buffers (checkout on the callback, checkin on the
    /// worker). Steady state allocates nothing per frame.
    private nonisolated let packPool = FramePackPool()
    /// Bounds queued pushes so a slow core/VT drops frames (like
    /// alwaysDiscardsLateVideoFrames did) instead of growing a backlog.
    private nonisolated let pushGate = InFlightGate()
    /// Stats publish at most 1/s (was: every frame to main).
    private nonisolated let statsGate = StatsGate()

    /// Enable/disable live-send encoding (call when a live call connects).
    public func setLiveSend(_ on: Bool) {
        liveFlag.set(on)
        if !on { liveBox.reset() }
    }

    public var liveSend: Bool { liveFlag.get() }

    override public init() {
        selectedDeviceID = UserDefaults.standard.string(forKey: Self.deviceKey)
        super.init()
    }

    /// Cameras available right now (no permission needed to list).
    public static func videoDevices() -> [CameraDevice] {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
        return found.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Request camera access. True = granted.
    public static func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
        }
    }

    /// Start capture (device picks nearest preset to the request).
    /// Configure runs on-main (fast); only startRunning blocks (queue).
    public func start(width: Int = 320, height: Int = 240, fps: Int = 15) {
        guard !running else { return }
        status = "starting…"
        do {
            try configure(fps: fps)
        } catch {
            status = "failed: \(error.localizedDescription)"
            return
        }
        let session = session
        queue.async { [weak self] in
            session.startRunning()
            do {
                _ = try RustCore.cameraBegin(
                    width: Int32(width), height: Int32(height), fps: Int32(fps))
                let stats = try RustCore.cameraStats()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastStats = stats
                    self.running = true
                    self.status = "capturing"
                }
            } catch {
                session.stopRunning()
                Task { @MainActor [weak self] in
                    self?.status = "failed: \(error.localizedDescription)"
                }
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        status = "stopping…"
        let session = session
        let box = liveBox
        let flag = liveFlag
        queue.async { [weak self] in
            session.stopRunning()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            try? RustCore.cameraEnd()
            flag.set(false)
            box.reset()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.output = nil
                self.status = "stopped"
            }
        }
    }

    /// Switch cameras live: stop, then start on the new pick.
    private func restart() {
        let wasRunning = running
        stop()
        guard wasRunning else { return }
        // stop() tears down async on the queue; re-start after it drains.
        queue.async { [weak self] in
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    private func configure(fps: Int) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480

        let device: AVCaptureDevice? = if let want = selectedDeviceID {
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video, position: .unspecified
            ).devices.first(where: { $0.uniqueID == want })
                ?? AVCaptureDevice.default(for: .video)
        } else {
            AVCaptureDevice.default(for: .video)
        }
        guard let device else {
            throw CameraError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw CameraError.cannotAddOutput }
        session.addOutput(out)
        output = out

        // Ask for ~fps on the device (best effort).
        if let conn = out.connection(with: .video),
           conn.isVideoMinFrameDurationSupported
        {
            conn.videoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        }
    }
}

/// NSLock-guarded counter (delegate-queue use from a @MainActor class).
private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock(); defer { lock.unlock() }; value += 1
    }
    var current: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) {
        lock.lock(); defer { lock.unlock() }; value = v
    }
    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Queue-confined stream encoder: created lazily at first live frame,
/// recreated when capture dims change. Encode runs off the lock.
private final class StreamEncoderBox: @unchecked Sendable {
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

public enum CameraError: Error, Sendable {
    case noDevice
    case cannotAddInput
    case cannotAddOutput
}

// MARK: - Frame delegate (private queue)

/// Stats-publish gate: first stats always publish, then at most 1/s.
public enum CameraStatsGate {
    public static let minIntervalMs: UInt64 = 1000

    public static func shouldPublish(nowMs: UInt64, lastMs: UInt64?) -> Bool {
        guard let lastMs else { return true }
        return nowMs &- lastMs >= minIntervalMs
    }

    static func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

/// Locked last-publish timestamp for the stats gate (worker-side use).
private final class StatsGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastMs: UInt64?

    /// True when this publish may go through (records the timestamp).
    func take(nowMs: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard CameraStatsGate.shouldPublish(nowMs: nowMs, lastMs: lastMs) else {
            return false
        }
        lastMs = nowMs
        return true
    }
}

/// Bounded in-flight counter: the callback drops the frame when the push
/// worker is already this deep, so a slow core/VT sheds load instead of
/// queueing latency.
private final class InFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0
    let limit: Int

    init(limit: Int = 3) { self.limit = limit }

    func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard depth < limit else { return false }
        depth += 1
        return true
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        depth = Swift.max(0, depth - 1)
    }
}

/// Small pool of reusable pack buffers. The callback checks one out,
/// packs rows into it, and the push worker checks it back in; extras
/// are dropped. All methods are lock-guarded (two queues touch it).
private final class FramePackPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [Data] = []
    let limit: Int

    init(limit: Int = 3) { self.limit = limit }

    /// A buffer of exactly `need` bytes, reused when one fits.
    func checkout(need: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        if let i = free.firstIndex(where: { $0.count == need }) {
            return free.remove(at: i)
        }
        free.removeAll(where: { $0.count != need })
        return Data(count: need)
    }

    func checkin(_ buf: Data) {
        lock.lock(); defer { lock.unlock() }
        guard free.count < limit, free.allSatisfy({ $0.count == buf.count }) else {
            return
        }
        free.append(buf)
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        guard pushGate.enter() else { return } // worker saturated: drop
        // Pack tightly into a reused buffer (stride may exceed w*4).
        var packed = packPool.checkout(need: w * h * 4)
        packed.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let d = dst.baseAddress!
            if stride == w * 4 {
                memcpy(d, base, w * h * 4) // tight rows: one copy
            } else {
                for row in 0 ..< h {
                    memcpy(d + row * w * 4, base + row * stride, w * 4)
                }
            }
        }
        // The core push + VT encode run off the callback (serial worker
        // preserves frame order); the callback returns to AVFoundation now.
        let worker = pushQueue
        let pool = packPool
        let gate = pushGate
        let counts = pushCount
        let box = liveBox
        let flag = liveFlag
        let stats = statsGate
        worker.async { [weak self] in
            defer {
                pool.checkin(packed)
                gate.leave()
            }
            do {
                let s = try RustCore.cameraPush(
                    pixels: packed, width: w, height: h, fmt: "bgra")
                counts.increment()
                if stats.take(nowMs: CameraStatsGate.nowMs()) {
                    Task { @MainActor [weak self] in self?.lastStats = s }
                }
                if flag.get() {
                    // Live send: VT-encode + push NALs; transient failures
                    // drop the frame (engine falls back to black IDR idle).
                    do {
                        let nals = try box.encode(bgra: packed, width: w, height: h)
                        _ = try RustCore.videoSendPush(nals: nals)
                    } catch {
                        // First failure surfaces; the rest stay silent.
                        if counts.current == 1 {
                            Task { @MainActor [weak self] in
                                self?.status = "live encode: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            } catch {
                // Push failures are transient; surface at most the first one.
                if counts.current == 0 {
                    Task { @MainActor [weak self] in
                        self?.status = "push failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

// MARK: - Preview

/// Live camera preview (AVCaptureVideoPreviewLayer in an NSView).
public struct CameraPreviewView: NSViewRepresentable {
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) { self.session = session }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {}
}
