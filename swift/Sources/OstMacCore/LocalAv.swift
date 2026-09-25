// LocalAv.swift — R12 ffi-move-now B1/B2: av_info (B1) + tone_check (B2)
// moved from Rust FFI to Swift (static caps + deterministic DSP self-check).
import Foundation

extension CoreLocal {
    /// Static capability map (was `ostmac_av_info`). No hardware touched.
    static func avInfo() throws -> AvInfo {
        let data = try statusJSONData([
            "ok": true,
            "mic": "cpal",
            "speaker": "cpal",
            "camera": "avfoundation",
            "display": "swiftui",
            "tone": true,
            "packetizer": "rust-h264",
            "srtp": "rust-aes-128-cm",
            "dry_run": true,
        ])
        return try decodeOrThrow(AvInfo.self, from: data)
    }
}
