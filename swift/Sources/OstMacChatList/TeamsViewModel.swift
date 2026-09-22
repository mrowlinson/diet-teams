// TeamsViewModel.swift — loads joined teams via ostmac-core, owns browser state.
import Combine
import Foundation
import OstMacCore

/// Browser content state (mirrors ChatListState without realtime ingest:
/// channels open as conversations but never reorder the browser).
public enum TeamsState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty list in `teams`.
    case loaded
    /// Fetch succeeded with zero teams.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads the teams list off the main thread and publishes rows.
///
/// Default fetcher calls `RustCore.teams` (blocking FFI + network) on a
/// detached task. Tests inject a mock fetcher.
@MainActor
public final class TeamsViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Fetcher = @Sendable () throws -> TeamsResponse

    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var teams: [TeamItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: TeamsState = .loading

    private let fetcher: Fetcher

    public init(fetcher: @escaping Fetcher = { try RustCore.teams() }) {
        self.fetcher = fetcher
    }

    /// Fetch the list.
    public func load() async {
        state = .loading
        let fetcher = fetcher
        do {
            let response = try await Task.detached {
                try fetcher()
            }.value
            teams = response.teams
            state = response.teams.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (toolbar button).
    public func refresh() {
        Task { await load() }
    }

    /// Channels matching `query` (case-insensitive); empty query matches all.
    /// Pure helper for the browser filter; team rows stay visible only when
    /// the team name or at least one of their channels matches.
    public nonisolated static func filtered(_ teams: [TeamItem], query: String) -> [TeamItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return teams }
        return teams.compactMap { team in
            if team.name.lowercased().contains(q) { return team }
            let channels = team.channels.filter { $0.name.lowercased().contains(q) }
            guard !channels.isEmpty else { return nil }
            return TeamItem(teamId: team.teamId, name: team.name, channels: channels)
        }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
