// Av.swift — om-av: A/V models + RustCore wrappers (mic/tone/camera/display/dry-run).
// Blocking calls (micTest, tonePlay) must run off the main thread; the panel
// ViewModel dispatches them with Task.detached.
import COstMac
import Foundation

// MARK: - Models

public struct AvInfo: Decodable, Sendable {
    public let ok: Bool
    public let mic: String
    public let speaker: String
    public let camera: String
    public let display: String
    public let tone: Bool
    public let packetizer: String
    public let srtp: String
    public let dry_run: Bool
}

public struct MicProbe: Decodable, Sendable {
    public let ok: Bool
    public let input: Bool
    public let output: Bool
}

public struct MicTestResult: Decodable, Sendable {
    public let ok: Bool
    public let frames: Int
    public let seconds: Double
    public let peak_db: Double
    public let played_back: Bool
}

public struct TonePlayResult: Decodable, Sendable {
    public let ok: Bool
    public let frames: Int
}

public struct ToneCheckResult: Decodable, Sendable {
    public let ok: Bool
    public let detected: Bool
    public let delay_ms: Double
    public let correlation_peak: Double
}

public struct CameraBegin: Decodable, Sendable {
    public let ok: Bool
    public let width: Int
    public let height: Int
    public let fps: Int
}

public struct CameraStats: Decodable, Sendable {
    public let ok: Bool
    public let running: Bool
    public let width: Int
    public let height: Int
    public let fps_want: Int
    public let frames: Int
    public let dropped: Int
    public let fps_actual: Double
    public let last_bytes: Int
}

public struct RemoteFrame: Decodable, Sendable {
    public let width: Int
    public let height: Int
    /// Planar I420 bytes, base64.
    public let data: String
}

public struct RemotePoll: Decodable, Sendable {
    public let ok: Bool
    public let frame: RemoteFrame?
}

public struct BlackIframe: Decodable, Sendable {
    public let ok: Bool
    public let width: Int
    public let height: Int
    /// Raw H.264 NALs (no start codes), base64: [SPS, PPS, IDR].
    public let nals: [String]
}

public struct DryRunResult: Decodable, Sendable {
    public let ok: Bool
    public let audio_sent: Int
    public let audio_received: Int
    public let echo_detected: Bool
    public let echo_delay_ms: Double
    public let echo_correlation: Double
    public let video_packets: Int
    public let video_nals: Int
}

public struct AudioDevices: Decodable, Sendable {
    public let ok: Bool
    public let inputs: [String]
    public let outputs: [String]
    public let default_input: String?
    public let default_output: String?
}

public struct MicLevel: Decodable, Sendable {
    public let ok: Bool
    public let peak_db: Double
    public let has_input: Bool
}

// MARK: - RustCore wrappers

/// Optional C string arg: nil/empty Swift string passes NULL (= default device).
func withOptCString<T>(_ s: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    guard let s, !s.isEmpty else { return try body(nil) }
    return try s.withCString { try body($0) }
}

public extension RustCore {
    static func avInfo() throws -> AvInfo {
        try call(ostmac_av_info(), as: AvInfo.self)
    }

    static func micProbe() throws -> MicProbe {
        try call(ostmac_mic_probe(), as: MicProbe.self)
    }

    /// Blocks ~`seconds` + playback. Call off-main.
    static func micTest(seconds: Int32 = 3) throws -> MicTestResult {
        try call(ostmac_mic_test(seconds), as: MicTestResult.self)
    }

    /// Blocks ~`msecs` while the tone plays. Call off-main.
    static func tonePlay(msecs: Int32 = 1000) throws -> TonePlayResult {
        try call(ostmac_tone_play(msecs), as: TonePlayResult.self)
    }

    static func toneCheck() throws -> ToneCheckResult {
        try call(ostmac_tone_check(), as: ToneCheckResult.self)
    }

    static func audioDevices() throws -> AudioDevices {
        try call(ostmac_audio_devices(), as: AudioDevices.self)
    }

    /// Named-device mic test (nil/"" = default). Blocks ~`seconds` + playback. Call off-main.
    static func micTestOn(seconds: Int32 = 3, input: String?, output: String?) throws -> MicTestResult {
        try withOptCString(input) { inPtr in
            try withOptCString(output) { outPtr in
                try call(ostmac_mic_test_on(seconds, inPtr, outPtr), as: MicTestResult.self)
            }
        }
    }

    /// Named-device tone play (nil/"" = default). Blocks ~`msecs`. Call off-main.
    static func tonePlayOn(msecs: Int32 = 1000, output: String?) throws -> TonePlayResult {
        try withOptCString(output) { outPtr in
            try call(ostmac_tone_play_on(msecs, outPtr), as: TonePlayResult.self)
        }
    }

    /// Short mic level sample for a live meter (nil/"" = default).
    /// Never throws for missing hardware (`has_input` tells). Call off-main.
    static func micLevel(msecs: Int32 = 150, input: String?) throws -> MicLevel {
        try withOptCString(input) { inPtr in
            try call(ostmac_mic_level(msecs, inPtr), as: MicLevel.self)
        }
    }

    static func cameraBegin(width: Int32, height: Int32, fps: Int32) throws -> CameraBegin {
        try call(ostmac_camera_begin(width, height, fps), as: CameraBegin.self)
    }

    static func cameraPush(pixelsB64: String, width: Int32, height: Int32, fmt: String) throws -> CameraStats {
        try pixelsB64.withCString { b64Ptr in
            try fmt.withCString { fmtPtr in
                try call(
                    ostmac_camera_push(b64Ptr, width, height, fmtPtr),
                    as: CameraStats.self)
            }
        }
    }

    static func cameraPush(pixels: Data, width: Int, height: Int, fmt: String) throws -> CameraStats {
        try cameraPush(
            pixelsB64: pixels.base64EncodedString(),
            width: Int32(width), height: Int32(height), fmt: fmt)
    }

    static func cameraStats() throws -> CameraStats {
        try call(ostmac_camera_stats(), as: CameraStats.self)
    }

    static func cameraEnd() throws {
        struct OkOnly: Decodable { let ok: Bool }
        let _: OkOnly = try call(ostmac_camera_end(), as: OkOnly.self)
    }

    static func videoPushRemote(i420: Data, width: Int, height: Int) throws {
        struct OkBytes: Decodable { let ok: Bool; let bytes: Int }
        let _: OkBytes = try i420.base64EncodedString().withCString { ptr in
            try call(
                ostmac_video_push_remote(ptr, Int32(width), Int32(height)),
                as: OkBytes.self)
        }
    }

    static func videoPollRemote() throws -> RemotePoll {
        try call(ostmac_video_poll_remote(), as: RemotePoll.self)
    }

    static func avBlackIframe() throws -> BlackIframe {
        try call(ostmac_av_black_iframe(), as: BlackIframe.self)
    }

    static func callDryRun() throws -> DryRunResult {
        try call(ostmac_call_dry_run(), as: DryRunResult.self)
    }
}
