// TenorPickerView.swift — om-cmdk lane: GIF picker popover for the composer.
// Trending on open, search on submit, thumbnails in a grid. No API key =
// graceful off-state pointing at Settings (no request is ever made).
import DietDesign
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
                        .foregroundStyle(DietColor.textSecondaryColor)
                    TextField("Search GIFs", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await runSearch() } }
                    if loading { ProgressView().controlSize(.small) }
                }
                .padding(10)
                DietSeamH()
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
        DietEmptyState(
            systemImage: "photo.on.rectangle.angled",
            title: "GIFs need a Tenor API key",
            message: "Add your free key in Settings → GIFs to enable the picker.")
    }

    private var grid: some View {
        Group {
            if let error {
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load GIFs",
                    message: error,
                    actionLabel: "Retry",
                    action: { Task { await loadTrending() } })
            } else if gifs.isEmpty, !loading {
                Text("No GIFs found.")
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(gifs) { gif in
                            Button { onPick(gif.fullURL) } label: {
                                AsyncImage(url: URL(string: gif.previewURL)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    case .failure:
                                        Color.gray.opacity(0.2)
                                            .overlay(Image(systemName: "photo")
                                                .foregroundStyle(DietColor.textSecondaryColor))
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
                        }
                    }
                    .padding(10)
                }
            }
        }
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
