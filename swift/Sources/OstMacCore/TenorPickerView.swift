// TenorPickerView.swift — om-cmdk lane: GIF picker popover for the composer.
// Trending on open, search on submit, thumbnails in a grid. No API key =
// graceful off-state pointing at Settings (no request is ever made).
import SwiftUI

/// GIF picker. `onPick` fires with the full-size GIF URL; the host inserts
/// it into the draft (or sends it) and dismisses the popover.
public struct TenorPickerView: View {
    private let apiKey: String
    private let onPick: (String) -> Void
    @State private var query = ""
    @State private var gifs: [TenorGIF] = []
    @State private var loading = false
    @State private var error: String?

    /// Roving arrow-key highlight over `gifs` (om-a3-keyboard).
    @State private var highlight = 0

    public init(apiKey: String, onPick: @escaping (String) -> Void) {
        self.apiKey = apiKey
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 0) {
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                offState
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search GIFs", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await runSearch() } }
                    if loading { ProgressView().controlSize(.small) }
                }
                .padding(10)
                Divider()
                grid
            }
        }
        .frame(width: 380, height: 320)
        .task {
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await loadTrending()
        }
    }

    private var offState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("GIFs need a Tenor API key").font(.headline)
            Text("Add your free key in Settings → GIFs to enable the picker.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        Group {
            if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(error).font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry") { Task { await loadTrending() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if gifs.isEmpty, !loading {
                Text("No GIFs found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(Array(gifs.enumerated()), id: \.element.id) { i, gif in
                                Button { onPick(gif.fullURL) } label: {
                                    AsyncImage(url: URL(string: gif.previewURL)) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        case .failure:
                                            Color.gray.opacity(0.2)
                                                .overlay(Image(systemName: "photo")
                                                    .foregroundStyle(.secondary))
                                        case .empty:
                                            Color.gray.opacity(0.12)
                                        @unknown default:
                                            Color.gray.opacity(0.12)
                                        }
                                    }
                                    .frame(height: 90)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .help(gif.title.isEmpty ? "Send GIF" : gif.title)
                                .accessibilityLabel(
                                    gif.title.isEmpty ? "GIF" : gif.title)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(
                                            i == highlight ? Color.accentColor : Color.clear,
                                            lineWidth: 2))
                                .id(i)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: highlight) { proxy.scrollTo($0, anchor: .center) }
                }
                .onChange(of: gifs) { highlight = 0 }
                // Field Return stays search (existing onSubmit); arrows
                // rove the grid, Return on a focused cell picks natively.
                .onKeyPress(.upArrow) { arrow(dx: 0, dy: -1) }
                .onKeyPress(.downArrow) { arrow(dx: 0, dy: 1) }
                .onKeyPress(.leftArrow) { arrow(dx: -1, dy: 0) }
                .onKeyPress(.rightArrow) { arrow(dx: 1, dy: 0) }
            }
        }
    }

    /// Adaptive columns rendered for the fixed 380pt width: same
    /// minimum + spacing the LazyVGrid uses, so arrow steps match.
    private var columns: Int {
        max(1, Int((380 - 20 + 8) / (100 + 8)))
    }

    private func arrow(dx: Int, dy: Int) -> KeyPress.Result {
        highlight = GridNav.move(
            current: highlight, dx: dx, dy: dy,
            columns: columns, count: gifs.count)
        return .handled
    }

    private func loadTrending() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            gifs = try await TenorClient.featured(apiKey: apiKey)
        } catch {
            self.error = message(for: error)
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            await loadTrending()
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            gifs = try await TenorClient.search(query: q, apiKey: apiKey)
        } catch {
            self.error = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if case TenorError.badResponse(let m) = error { return "Tenor: \(m)" }
        if case TenorError.network(let m) = error { return "Network: \(m)" }
        return String(describing: error)
    }
}
