// TeamsTabsView.swift — om-h4-tabs lane: channel tabs row (read-only).
//
// Graph pinned tabs (Posts, Files, Notes, website tabs, ...) as a chip
// row above the conversation. Taps deep-link: Posts -> Chat tab, Files ->
// Shared tab, Notes -> Notes tab, website tabs -> browser. No tab content
// is rendered here; unknown tabs without a URL render dimmed (no-op).
//
//   let tabs = ChannelTabsStore()
//   tabs.open(channelID: "19:...@thread.tacv2")
//   TeamsTabsView(store: tabs, selected: .chat) { target in ... }
// Tests inject a mock list fetcher (same seam as SharedFilesStore).
import DietDesign
import SwiftUI

/// Channel-tabs content state.
public enum ChannelTabsState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
}

@MainActor
public final class ChannelTabsStore: ObservableObject {
    public typealias ListFetcher = @Sendable (String) throws -> TabsResponse

    @Published public private(set) var tabs: [ChannelTab] = []
    @Published public private(set) var state: ChannelTabsState = .idle
    public private(set) var channelID: String?

    private let listFetcher: ListFetcher
    private var openGeneration = 0

    public nonisolated init(
        list: @escaping ListFetcher = { try RustCore.tabs(channelID: $0) }
    ) {
        self.listFetcher = list
    }

    /// Channel ids are `19:...@thread.tacv2` (ost files.rs parity).
    /// Plain chat ids never open the tabs row.
    public static func isChannelID(_ id: String) -> Bool {
        let t = id.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("19:") && t.hasSuffix("@thread.tacv2")
    }

    /// Open a channel: fetch its tabs via core, replace the row.
    /// Non-channel ids reset to idle (no fetch). Stale completions are
    /// dropped (fast channel-switching lands newest).
    public func open(channelID: String) {
        openGeneration += 1
        let gen = openGeneration
        guard Self.isChannelID(channelID) else {
            self.channelID = nil
            tabs = []
            state = .idle
            return
        }
        self.channelID = channelID
        state = .loading
        Task {
            let fetcher = listFetcher
            do {
                let resp = try await Task.detached { try fetcher(channelID) }.value
                guard gen == openGeneration else { return }
                tabs = resp.tabs
                state = resp.tabs.isEmpty ? .empty : .loaded
            } catch {
                guard gen == openGeneration else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Fire-and-forget reload.
    public func refresh() {
        guard let id = channelID else { return }
        open(channelID: id)
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}

/// Pinned-tabs chip row. `selected` highlights the chip whose target the
/// host is showing; `onSelect` deep-links (host maps targets to its Chat
/// / Shared / Notes tabs, `.web` to the browser, `.none` to a no-op).
public struct TeamsTabsView: View {
    @ObservedObject public var store: ChannelTabsStore
    private let selected: ChannelTabTarget
    private let onSelect: (ChannelTabTarget) -> Void

    public init(
        store: ChannelTabsStore,
        selected: ChannelTabTarget = .chat,
        onSelect: @escaping (ChannelTabTarget) -> Void
    ) {
        self.store = store
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        switch store.state {
        case .idle, .empty:
            EmptyView()
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading tabs…")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                Spacer()
            }
            .padding(.horizontal, DietSpace.md)
            .padding(.vertical, DietSpace.xs)
        case let .error(message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color(nsColor: DietColor.warning))
                Text(message)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
                Button("Retry") { store.refresh() }
                    .buttonStyle(.link)
                    .font(DietType.caption1)
                Spacer()
            }
            .padding(.horizontal, DietSpace.md)
            .padding(.vertical, DietSpace.xs)
        case .loaded:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.tabs) { tab in
                        chip(for: tab)
                    }
                }
                .padding(.horizontal, DietSpace.md)
                .padding(.vertical, DietSpace.xs)
            }
        }
    }

    private func chip(for tab: ChannelTab) -> some View {
        let target = tab.target
        // URL equality on .web values: only highlight exact matches.
        let highlighted: Bool = {
            switch (target, selected) {
            case (.chat, .chat), (.shared, .shared), (.notes, .notes):
                return true
            case let (.web(a), .web(b)):
                return a == b
            default:
                return false
            }
        }()
        return Button {
            onSelect(target)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon(for: target))
                    .font(DietType.caption2)
                Text(tab.name)
                    .font(DietType.caption1)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                highlighted
                    ? Color(nsColor: DietColor.accent).opacity(0.25)
                    : Color.secondary.opacity(0.12)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            target == .none ? DietColor.textTertiaryColor : DietColor.textPrimaryColor)
        .disabled(target == .none)
        .help(hint(for: tab))
    }

    private func icon(for target: ChannelTabTarget) -> String {
        switch target {
        case .chat: return "bubble.left.and.bubble.right"
        case .shared: return "folder"
        case .notes: return "note.text"
        case .web: return "safari"
        case .none: return "questionmark.circle"
        }
    }

    private func hint(for tab: ChannelTab) -> String {
        switch tab.target {
        case .chat: return "Show the Posts conversation"
        case .shared: return "Show channel files"
        case .notes: return "Show the channel notebook"
        case let .web(url): return "Open \(url.absoluteString) in the browser"
        case .none: return "\(tab.name): no link target"
        }
    }
}
