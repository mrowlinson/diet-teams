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
    /// Touched only from the delegate queue (serial); locked for Sendable.
    private nonisolated let pushCount = LockedInt()

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
        queue.async { [weak self] in
            session.stopRunning()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            try? RustCore.cameraEnd()
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

public enum CameraError: Error, Sendable {
    case noDevice
    case cannotAddInput
    case cannotAddOutput
}

// MARK: - Frame delegate (private queue)

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
        // Pack tightly (stride may exceed w*4).
        var packed = Data(count: w * h * 4)
        packed.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let d = dst.baseAddress!
            for row in 0 ..< h {
                memcpy(d + row * w * 4, base + row * stride, w * 4)
            }
        }
        do {
            let stats = try RustCore.cameraPush(
                pixels: packed, width: w, height: h, fmt: "bgra")
            pushCount.increment()
            Task { @MainActor [weak self] in self?.lastStats = stats }
        } catch {
            // Push failures are transient; surface at most the first one.
            if pushCount.current == 0 {
                Task { @MainActor [weak self] in
                    self?.status = "push failed: \(error.localizedDescription)"
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
