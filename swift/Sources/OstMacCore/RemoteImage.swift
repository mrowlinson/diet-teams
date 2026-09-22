// RemoteImage.swift — om-richmedia: bubble image with load states.
//
// States: loading (placeholder) → loaded (aspect-fit, tap-to-expand sheet)
// or failed (icon + retry). Bytes come from RichMediaCache (URL+msg keyed),
// so paging/streaming re-renders never refetch.
import AppKit
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
            guard let img = NSImage(data: data) else {
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

/// Full-size bubble image: 260×200 cap, aspect fit, tap expands.
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
                        .frame(width: 260, height: 160)
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
                            .frame(maxWidth: 260, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                    .sheet(isPresented: $expanded) {
                        ZoomedImage(image: img, alt: alt)
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
        .onAppear { model.load() }
    }
}

/// Tap-to-expand sheet: the same bytes, bigger cap.
struct ZoomedImage: View {
    let image: NSImage
    let alt: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 640, maxHeight: 480)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding()
        .frame(minWidth: 320, minHeight: 240)
        .accessibilityLabel(alt.isEmpty ? "Expanded image" : "Expanded \(alt)")
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
