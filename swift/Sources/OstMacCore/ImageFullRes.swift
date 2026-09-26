// ImageFullRes.swift — om-imgfull: viewer loads full-res, not thumbnail.
//
// The bubble keeps its thumbnail URL (list scrolling + preload untouched).
// On open, the viewer derives the full-resolution URL and fetches it
// through RichMediaCache (its own URL+message key, so thumb and full
// cache independently). While loading, the thumbnail stays on screen
// behind a progress pill; on failure the thumbnail stays up with an
// error row + Retry (the viewer is still useful offline).
import AppKit
import SwiftUI

/// Pure full-res URL derivation (testable without actors or views).
public enum ImageFullRes {
    /// Full view for AMS object URLs (`…/views/<thumb>` → `…/views/imgo`).
    public static let fullView = "imgo"
    /// Already-full views (never rewritten).
    public static let fullViews = ["imgo", "imgpsh_fullsize"]

    /// Thumbnail URL → full-resolution URL.
    /// - AMS object views: the `/views/<name>` segment becomes `imgo`
    ///   (query/fragment preserved); already-full views untouched.
    /// - `demo://` fixtures: `demo://photo-N` → `demo://photo-N-full`
    ///   (2× render); already-full untouched.
    /// - Everything else (public URLs, emoticons): unchanged — the
    ///   single URL already is the full image.
    public static func fullResURL(for url: String) -> String {
        if url.hasPrefix("demo://") {
            return url.hasSuffix("-full") ? url : url + "-full"
        }
        guard let views = url.range(of: "/views/", options: .caseInsensitive) else {
            return url
        }
        let nameStart = views.upperBound
        var nameEnd = url.endIndex
        for i in url[nameStart...].indices {
            let c = url[i]
            if c == "/" || c == "?" || c == "#" {
                nameEnd = i
                break
            }
        }
        let name = String(url[nameStart ..< nameEnd])
        if fullViews.contains(name.lowercased()) { return url }
        return String(url[..<nameStart]) + fullView + String(url[nameEnd...])
    }
}

/// Full-res load state for one open viewer. Mirrors RemoteImageModel's
/// shape (phase + image + reload) with the thumbnail held alongside:
/// the view shows `image ?? thumb` so loading and failure never blank.
@MainActor
public final class FullResImageModel: ObservableObject {
    @Published public private(set) var phase: RemoteImagePhase = .loading
    @Published public private(set) var image: NSImage?
    /// Decoded animation when the full-res bytes are multi-frame
    /// (om-gif-playback). `image` still holds frame 0.
    @Published public private(set) var gif: GifClip?
    public var isAnimated: Bool { gif != nil }
    public let thumbURL: String
    public let fullURL: String
    public let messageID: String
    public let thumb: NSImage?
    private let cache: RichMediaCache
    private let fetcher: RichMediaCache.Fetcher
    private let decodedCache: DecodedImageCache

    public init(
        thumbURL: String, messageID: String,
        thumb: NSImage? = nil,
        cache: RichMediaCache = .shared,
        fetcher: RichMediaCache.Fetcher? = nil,
        decodedCache: DecodedImageCache = .shared
    ) {
        self.thumbURL = thumbURL
        self.fullURL = ImageFullRes.fullResURL(for: thumbURL)
        self.messageID = messageID
        self.thumb = thumb
        self.cache = cache
        self.fetcher = fetcher ?? RichMediaCache.defaultFetch
        self.decodedCache = decodedCache
    }

    /// Load once; no-op while loaded or already loading.
    public func load() {
        guard phase == .loading, image == nil else { return }
        Task { await reload() }
    }

    /// Fetch full-res bytes (cache first), decoding to an image.
    /// The thumbnail is untouched throughout — it stays on screen
    /// behind loading and failure states.
    public func reload() async {
        phase = .loading
        image = nil
        gif = nil
        do {
            let data = try await cache.data(
                url: fullURL, messageID: messageID, fetcher: fetcher)
            // Memoized one-source decode (reopens reuse the stored
            // image instead of re-decoding the same bytes per open).
            guard let result = await decodedCache.decoded(
                data: data, maxPixels: ImageDecode.viewerMaxPixels)
            else {
                phase = .failed("not an image")
                return
            }
            switch result {
            case let .still(img):
                image = img
            case let .animated(clip):
                image = clip.frames.first
                gif = clip
            }
            phase = .loaded
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
