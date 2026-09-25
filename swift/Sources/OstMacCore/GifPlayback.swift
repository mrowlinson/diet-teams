// GifPlayback.swift — om-gif-playback: animated GIF detect + clip + play gate.
//
// Inline GIFs animate like Teams: the bubble shows the looping clip with
// a native play/stop overlay instead of the old static first frame.
// Reduce Motion starts paused on the first frame (DietMotion precedent);
// pressing play is explicit user intent and animates either way.
// Pure probe/math stays testable without views; decoding runs off-main.
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Animated-GIF detection over raw bytes. Nil where the bytes are not a
/// decodable image at all (mirrors `NSImage(data:)` rejection).
public enum GifProbe {
    /// Browsers clamp near-zero GIF delays; below this a frame would
    /// strobe. Matches the fastest sane frame step.
    public static let minFrameDuration = 0.02

    public static func source(data: Data) -> CGImageSource? {
        guard !data.isEmpty else { return nil }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    /// Frame count for any decodable image (stills report 1).
    public static func frameCount(_ data: Data) -> Int? {
        guard let src = source(data: data) else { return nil }
        let n = CGImageSourceGetCount(src)
        return n > 0 ? n : nil
    }

    /// True only for multi-frame GIFs. Single-frame GIFs and every
    /// still format take the static path (no overlay, no timers).
    public static func isAnimated(_ data: Data) -> Bool {
        guard let src = source(data: data) else { return false }
        guard let type = CGImageSourceGetType(src) as String?,
              UTType(type)?.conforms(to: .gif) == true
        else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// Per-frame display durations in seconds, clamped to the minimum.
    /// Nil for non-images; stills report their single frame.
    public static func durations(_ data: Data) -> [Double]? {
        guard let src = source(data: data) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        return (0 ..< n).map { duration(src: src, index: $0) }
    }

    static func duration(src: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil)
            as? [CFString: Any],
            let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        let d = unclamped > 0 ? unclamped : clamped
        return max(d > 0 ? d : 0.1, minFrameDuration)
    }
}

/// Decoded animation: downsampled frames + durations. Nil unless the
/// bytes are an animated GIF (see GifProbe).
public struct GifClip: Sendable {
    public let frames: [NSImage]
    public let durations: [Double]

    /// Frame cap: huge GIFs stride-sample down to this many frames
    /// (durations scale by the stride, so the loop keeps its length).
    public static let maxFrames = 60

    public init(frames: [NSImage], durations: [Double]) {
        self.frames = frames
        self.durations = durations
    }

    public var totalDuration: Double { durations.reduce(0, +) }

    /// Stride-sampled frame indices for a count over the cap.
    /// Pure so tests pin the sampling without a 200-frame fixture.
    public static func sampledIndices(count: Int, max: Int = maxFrames) -> [Int] {
        guard count > max, max > 0 else { return Array(0 ..< Swift.max(count, 0)) }
        let stride = Double(count) / Double(max)
        return (0 ..< max).map { Int(Double($0) * stride) }
    }

    /// Loop position → frame index. Degenerate inputs (no/zero total
    /// duration, negative time) pin to frame 0; time wraps modulo the loop.
    public static func frameIndex(at time: Double, durations: [Double]) -> Int {
        guard !durations.isEmpty else { return 0 }
        let total = durations.reduce(0, +)
        guard total > 0, time > 0 else { return 0 }
        var t = time.truncatingRemainder(dividingBy: total)
        // Exact loop boundary (t == 0 after wrap, time > 0) restarts at 0.
        if t == 0 { return 0 }
        for (i, d) in durations.enumerated() {
            if t < d { return i }
            t -= d
        }
        return durations.count - 1
    }

    /// Downsampled per-frame decode, synchronous (call off the main thread).
    public static func decode(data: Data, maxPixels: CGFloat) -> GifClip? {
        guard GifProbe.isAnimated(data),
              let src = GifProbe.source(data: data)
        else { return nil }
        let count = CGImageSourceGetCount(src)
        let indices = sampledIndices(count: count)
        let stride = Double(count) / Double(Swift.max(indices.count, 1))
        let opts: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        var frames: [NSImage] = []
        var durations: [Double] = []
        frames.reserveCapacity(indices.count)
        for i in indices {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts) else {
                return nil
            }
            frames.append(NSImage(
                cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            durations.append(GifProbe.duration(src: src, index: i) * stride)
        }
        guard !frames.isEmpty else { return nil }
        return GifClip(frames: frames, durations: durations)
    }

    /// Downsampled per-frame decode off the caller's actor.
    public static func decodeOffMain(data: Data, maxPixels: CGFloat) async -> GifClip? {
        await Task.detached(priority: .userInitiated) {
            decode(data: data, maxPixels: maxPixels)
        }.value
    }
}

/// Play/stop + Reduce Motion gate. Pure so tests pin the contract.
public enum GifPlayback {
    /// Autoplay iff the bytes animate and Reduce Motion is off.
    /// The overlay toggle always stays available (explicit user intent).
    public static func initiallyPlaying(animated: Bool, reduceMotion: Bool) -> Bool {
        animated && !reduceMotion
    }
}
