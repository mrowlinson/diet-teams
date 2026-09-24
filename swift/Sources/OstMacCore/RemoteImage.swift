// RemoteImage.swift — om-richmedia/om-scroll: bubble image with load states.
//
// States: loading (placeholder) → loaded (aspect-fit, tap-to-expand sheet)
// or failed (icon + retry). Bytes come from RichMediaCache (URL+msg keyed),
// so paging/streaming re-renders never refetch. All phases share one fixed
// slot (RemoteImageSlot) so resolving bytes never shifts the timeline.
import AppKit
import DietDesign
import SwiftUI

/// Load state for one bubble image. Plain enum keeps the state machine
/// testable without views.
public enum RemoteImagePhase: Sendable, Equatable {
    case loading
    case loaded
    case failed(String)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.loaded, .loaded): return true
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}

@MainActor
public final class RemoteImageModel: ObservableObject {
    @Published public private(set) var phase: RemoteImagePhase = .loading
    @Published public private(set) var image: NSImage?
    public private(set) var url: String
    public private(set) var messageID: String
    private let cache: RichMediaCache
    private let fetcher: RichMediaCache.Fetcher

    public init(
        url: String, messageID: String,
        cache: RichMediaCache = .shared,
        fetcher: RichMediaCache.Fetcher? = nil
    ) {
        self.url = url
        self.messageID = messageID
        self.cache = cache
        self.fetcher = fetcher ?? RichMediaCache.defaultFetch
    }

    /// Load once; no-op while loaded or already loading the same key.
    public func load() {
        guard phase == .loading, image == nil else { return }
        Task { await reload() }
    }

    public func reload() async {
        phase = .loading
        image = nil
        do {
            let data = try await cache.data(url: url, messageID: messageID, fetcher: fetcher)
            guard let img = await ImageDecode.decodeOffMain(
                data: data, maxPixels: ImageDecode.bubbleMaxPixels)
            else {
                phase = .failed("not an image")
                return
            }
            image = img
            phase = .loaded
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

/// Stable slot shared by every image phase (om-scroll): loading,
/// loaded, and failed all occupy the same box, so resolving bytes never
/// shifts the timeline (the short-land/settle counterpart at the row level).
public enum RemoteImageSlot {
    public static let width: CGFloat = 260
    public static let height: CGFloat = 200
    /// Emoticon row height, all states (failed alt text may run wider —
    /// horizontal only, never a vertical shift).
    public static let emoticonHeight: CGFloat = 22

    public static func size(for _: RemoteImagePhase) -> CGSize {
        CGSize(width: width, height: height)
    }
}

/// Full-size bubble image: fixed 260×200 slot, aspect fit, tap expands.
public struct RemoteImage: View {
    @StateObject private var model: RemoteImageModel
    private let alt: String
    @State private var expanded = false

    public init(url: String, messageID: String, alt: String = "") {
        _model = StateObject(wrappedValue: RemoteImageModel(url: url, messageID: messageID))
        self.alt = alt
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.25))
                    ProgressView()
                        .controlSize(.small)
                }
                .accessibilityLabel(alt.isEmpty ? "Loading image" : "Loading \(alt)")
            case .loaded:
                if let img = model.image {
                    Button { expanded = true } label: {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: RemoteImageSlot.width, maxHeight: RemoteImageSlot.height)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                    .sheet(isPresented: $expanded) {
                        ZoomedImage(
                            thumb: img, url: model.url,
                            messageID: model.messageID, alt: alt)
                    }
                }
            case let .failed(err):
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text(alt.isEmpty ? "Couldn't load image" : "Couldn't load \(alt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Retry") { Task { await model.reload() } }
                        .font(.caption)
                        .buttonStyle(.link)
                }
                .padding(8)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .help(err)
            }
        }
        .frame(width: RemoteImageSlot.width, height: RemoteImageSlot.height)
        .onAppear { model.load() }
    }
}

/// Tap-to-expand viewer: fetches FULL-RES on open (om-imgfull), the
/// bubble thumbnail stays on screen behind loading and failure states.
/// Resizable window (remembers its size for the session), magnification
/// slider pinned at the bottom (25%…400%, fit-width default), live zoom
/// with trackpad-scroll and drag panning via an NSScrollView host.
/// Open/close behavior is unchanged: it opens as a sheet from the bubble
/// image and closes via Close or Esc.
struct ZoomedImage: View {
    @StateObject private var full: FullResImageModel
    let alt: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: Double
    @State private var viewportWidth: CGFloat = 0
    @State private var didFit = false
    @State private var userTouchedZoom = false
    @State private var fixedSize: CGSize? = ImageViewerSession.lastSize

    init(thumb: NSImage, url: String, messageID: String, alt: String) {
        _full = StateObject(wrappedValue: FullResImageModel(
            thumbURL: url, messageID: messageID, thumb: thumb))
        self.alt = alt
        // First guess before layout runs; fitOnce refines it to the real
        // viewport on appear.
        _scale = State(wrappedValue: ImageZoom.fitWidthScale(
            imageWidth: thumb.size.width,
            viewportWidth: ImageViewerSession.initialSize().width))
    }

    /// Full-res bytes when loaded, else the thumbnail (never blank).
    private var display: NSImage? { full.image ?? full.thumb }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    if let display {
                        ZoomScrollView(image: display, scale: scale)
                            .onAppear {
                                viewportWidth = geo.size.width
                                fitOnce(viewportWidth: geo.size.width)
                            }
                            .onChange(of: geo.size) { _, newSize in
                                viewportWidth = newSize.width
                                fitOnce(viewportWidth: newSize.width)
                            }
                    } else {
                        ProgressView("Loading full resolution…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if full.phase == .loading, display != nil {
                        VStack {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading full resolution…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thickMaterial)
                            .clipShape(Capsule())
                            Spacer()
                        }
                        .padding(8)
                    }
                }
                .onChange(of: full.phase) { _, new in
                    // Full bytes swapped the display size: refit unless the
                    // user already chose a zoom (a pending first layout
                    // fits the full image itself).
                    if new == .loaded, didFit, !userTouchedZoom,
                       let img = full.image, viewportWidth > 0
                    {
                        scale = ImageZoom.fitWidthScale(
                            imageWidth: img.size.width,
                            viewportWidth: viewportWidth)
                    }
                }
            }
            if case let .failed(err) = full.phase {
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text("Full resolution unavailable — showing preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Retry") { Task { await full.reload() } }
                        .font(.caption)
                        .buttonStyle(.link)
                }
                .padding(8)
                .help(err)
                DietDividerH()
            }
            DietDividerH()
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { scale },
                        set: { scale = $0; userTouchedZoom = true }
                    ),
                    in: ImageZoom.minScale ... ImageZoom.maxScale,
                    label: { Text("Magnification") },
                    minimumValueLabel: { Text("25%") },
                    maximumValueLabel: { Text("400%") }
                )
                .frame(maxWidth: 280)
                .accessibilityLabel("Magnification")
                Text("\(Int(ImageZoom.sliderPercent(forScale: scale).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
                Button("Fit width") {
                    if let display {
                        scale = ImageZoom.fitWidthScale(
                            imageWidth: display.size.width,
                            viewportWidth: viewportWidth)
                    }
                }
                .disabled(viewportWidth <= 0)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(8)
        }
        .background(
            GeometryReader { outer in
                Color.clear
                    .onChange(of: outer.size) { _, newSize in
                        ImageViewerSession.remember(newSize)
                    }
            }
        )
        .frame(width: fixedSize?.width, height: fixedSize?.height)
        .frame(
            minWidth: ImageViewerSession.minSize.width,
            minHeight: ImageViewerSession.minSize.height
        )
        .onAppear {
            full.load()
            // Release the restored size after first layout so the window is
            // freely resizable; the size reader above keeps remembering it.
            if fixedSize != nil {
                DispatchQueue.main.async { fixedSize = nil }
            }
        }
        .accessibilityLabel(alt.isEmpty ? "Expanded image" : "Expanded \(alt)")
    }

    /// Fit-width default: applied once to the first real viewport; later
    /// resizes must not fight the user's chosen zoom. Fits whatever is
    /// on screen (thumbnail, then full-res after the swap refit above).
    private func fitOnce(viewportWidth: CGFloat) {
        guard !didFit, viewportWidth > 0, let display else { return }
        scale = ImageZoom.fitWidthScale(
            imageWidth: display.size.width, viewportWidth: viewportWidth)
        didFit = true
    }
}

/// Emoticon-sized art (≤32px markers): 22pt box, alt-text fallback.
public struct RemoteEmoticon: View {
    @StateObject private var model: RemoteImageModel
    private let alt: String

    public init(url: String, messageID: String, alt: String = "") {
        _model = StateObject(wrappedValue: RemoteImageModel(url: url, messageID: messageID))
        self.alt = alt
    }

    public var body: some View {
        Group {
            if let img = model.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            } else if model.phase == .loading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 22, height: 22)
            } else if !alt.isEmpty {
                Text(alt)
                    .font(.body)
                    .lineLimit(1)
                    .frame(height: RemoteImageSlot.emoticonHeight)
            } else {
                Image(systemName: "face.smiling")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
        }
        .onAppear { model.load() }
        .accessibilityLabel(alt.isEmpty ? "Emoji image" : alt)
    }
}
