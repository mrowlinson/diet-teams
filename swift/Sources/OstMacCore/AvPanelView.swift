// AvPanelView.swift — om-av: Call A/V test panel (mic/tone/camera/video/dry-run).
// Blocking core calls run via Task.detached; state publishes on-main.
import SwiftUI

@MainActor
public final class AvPanelModel: ObservableObject {
    @Published public var caps = "—"
    @Published public var probe = "—"
    @Published public var mic = "idle"
    @Published public var tone = "idle"
    @Published public var check = "idle"
    @Published public var dry = "idle"
    @Published public var decode = "idle"
    @Published public var busy = false
    @Published public var remoteImage: CGImage?
    @Published public var decodedImage: CGImage?

    public init() {}

    /// Off-main runner: `work` runs detached, `apply` publishes on-main.
    private func run<T: Sendable>(
        _ apply: @escaping @MainActor (Result<T, Error>) -> Void,
        work: @escaping @Sendable () throws -> T
    ) {
        busy = true
        Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try work()) } catch { result = .failure(error) }
            await MainActor.run {
                apply(result)
            }
        }
    }

    public func refreshCaps() {
        run({ [weak self] (r: Result<AvInfo, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.caps = "mic=\(v.mic) cam=\(v.camera) disp=\(v.display) pkt=\(v.packetizer)"
            case let .failure(e):
                self.caps = "failed: \(e.localizedDescription)"
            }
            self.busy = false
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
            self.busy = false
        }, work: { try RustCore.micProbe() })
    }

    public func runMicTest() {
        mic = "recording 3s…"
        run({ [weak self] (r: Result<MicTestResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.mic = String(
                    format: "%d frames %.1fs peak %.1fdB play=%@",
                    v.frames, v.seconds, v.peak_db, v.played_back ? "yes" : "no")
            case let .failure(e):
                self.mic = "failed: \(e.localizedDescription)"
            }
            self.busy = false
        }, work: { try RustCore.micTest() })
    }

    public func runTonePlay() {
        tone = "playing 1s…"
        run({ [weak self] (r: Result<TonePlayResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v): self.tone = "\(v.frames) frames played"
            case let .failure(e): self.tone = "failed: \(e.localizedDescription)"
            }
            self.busy = false
        }, work: { try RustCore.tonePlay() })
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
            self.busy = false
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
            self.busy = false
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
            self.busy = false
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
            self.busy = false
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

public struct AvPanelView: View {
    @StateObject private var model = AvPanelModel()
    @StateObject private var camera = CameraCapture()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    row("core", model.caps)
                    row("devices", model.probe)
                    HStack {
                        Button("Probe") { model.refreshCaps(); model.refreshProbe() }
                        Button("Mic test") { model.runMicTest() }
                        Text(model.mic).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Play tone") { model.runTonePlay() }
                        Text(model.tone).font(.caption).foregroundStyle(.secondary)
                        Button("Echo check") { model.runToneCheck() }
                        Text(model.check).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Dry run") { model.runDryRun() }
                        Text(model.dry).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Group {
                    Text("Camera (AVFoundation)").font(.headline)
                    HStack(alignment: .top) {
                        CameraPreviewView(session: camera.session)
                            .frame(width: 240, height: 180)
                            .border(.secondary)
                        VStack(alignment: .leading) {
                            Text(camera.status).font(.caption)
                            if let s = camera.lastStats {
                                Text("frames=\(s.frames) drops=\(s.dropped) " +
                                    String(format: "%.1ffps", s.fps_actual))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(camera.running ? "Stop" : "Start") {
                                    if camera.running { camera.stop() } else { startCamera() }
                                }
                            }
                        }
                    }
                }
                Divider()
                Group {
                    Text("Video (VideoToolbox + SwiftUI)").font(.headline)
                    HStack {
                        Button("VT round-trip") { model.runRoundTrip() }
                        Button("Remote loopback") { model.runRemoteLoopback() }
                        Text(model.decode).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        if let img = model.decodedImage {
                            Image(img, scale: 1, label: Text("decoded"))
                                .resizable().frame(width: 176, height: 144).border(.secondary)
                        }
                        if let img = model.remoteImage {
                            Image(img, scale: 1, label: Text("remote"))
                                .resizable().frame(width: 128, height: 128).border(.secondary)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 560)
        .task { model.refreshCaps(); model.refreshProbe() }
        .onDisappear { camera.stop() }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled)
        }
    }

    private func startCamera() {
        Task {
            guard await CameraCapture.requestAccess() else { return }
            camera.start()
        }
    }
}
