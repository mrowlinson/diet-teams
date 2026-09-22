// CameraCapture.swift — om-av: native macOS camera via AVFoundation.
// Feeds BGRA frames to the Rust camera pump (I420 convert + stats) and
// exposes the session for a SwiftUI preview layer. No V4L2.
import AVFoundation
import AppKit
import SwiftUI

/// AVCapture owner: BGRA frame output -> RustCore.cameraPush. Main-actor
/// published state; delegate callbacks arrive on a private queue.
@MainActor
public final class CameraCapture: NSObject, ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var status = "idle"
    @Published public private(set) var lastStats: CameraStats?

    public let session = AVCaptureSession()
    private var output: AVCaptureVideoDataOutput?
    private let queue = DispatchQueue(label: "dev.ostmac.camera")
    /// Touched only from the delegate queue (serial); locked for Sendable.
    private nonisolated let pushCount = LockedInt()
    /// Live-send path (om-liveav): VT-encode each frame and push NALs to the
    /// Rust send queue. Box is queue-confined; flag toggles from any thread.
    private nonisolated let liveBox = StreamEncoderBox()
    private nonisolated let liveFlag = LockedFlag()

    /// Enable/disable live-send encoding (call when a live call connects).
    public func setLiveSend(_ on: Bool) {
        liveFlag.set(on)
        if !on { liveBox.reset() }
    }

    public var liveSend: Bool { liveFlag.get() }

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

    private func configure(fps: Int) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(for: .video) else {
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
            if liveFlag.get() {
                // Live send: VT-encode + push NALs; transient failures drop
                // the frame (engine falls back to black IDR when idle).
                let box = liveBox
                do {
                    let nals = try box.encode(bgra: packed, width: w, height: h)
                    _ = try RustCore.videoSendPush(nals: nals)
                } catch {
                    // First failure surfaces; the rest stay silent.
                    if pushCount.current == 1 {
                        Task { @MainActor [weak self] in
                            self?.status = "live encode: \(error.localizedDescription)"
                        }
                    }
                }
            }
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
