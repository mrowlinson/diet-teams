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
    /// Sync channel create (runs off-main): team id, name, description.
    public typealias Creator = @Sendable (String, String, String?) throws -> ChannelCreateResponse
    /// Sync join-by-id (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Joiner = @Sendable (String) throws -> TeamJoinResponse

    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var teams: [TeamItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: TeamsState = .loading
    /// Last channel-create failure (user-facing); nil when clear.
    @Published public private(set) var createError: String?
    /// Team ids with a join in flight (drives row spinners).
    @Published public private(set) var joiningIDs: Set<String> = []
    /// Successful joins this session (test/UX counter).
    @Published public private(set) var joinsCompleted: Int = 0
    /// Failed joins this session (test/UX counter).
    @Published public private(set) var joinFailures: Int = 0
    /// Last join failure message, nil after a success or blank noop.
    @Published public private(set) var joinError: String?

    private let fetcher: Fetcher
    private let creator: Creator
    private let joiner: Joiner

    public init(
        fetcher: @escaping Fetcher = { try RustCore.teams() },
        creator: @escaping Creator = { try RustCore.channelCreate(teamID: $0, name: $1, description: $2) },
        joiner: @escaping Joiner = { try RustCore.teamJoin(teamID: $0) }
    ) {
        self.fetcher = fetcher
        self.creator = creator
        self.joiner = joiner
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

    /// Fire-and-forget reload (error-state Retry, sign-in).
    public func refresh() {
        Task { await load() }
    }

    /// Create one channel in a team, appending the returned row. Blank
    /// names never reach core; an unknown team id (stale list) lands
    /// silently. Failures surface in `createError`.
    public func createChannel(teamID: String, name: String, description: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        createError = nil
        let creator = creator
        do {
            let created = try await Task.detached {
                try creator(teamID, trimmed, description)
            }.value
            guard let idx = teams.firstIndex(where: { $0.teamId == teamID }) else { return }
            let row = teams[idx]
            teams[idx] = TeamItem(
                teamId: row.teamId, name: row.name,
                channels: row.channels + [created.channel])
        } catch {
            createError = Self.message(for: error)
        }
    }

    /// Join one team by id, then reload the list so the new team shows.
    /// Blank ids are a noop (joiner never runs). Runs the blocking join
    /// off-main on a detached task; `joiningIDs` tracks flight.
    public func join(teamID: String) async {
        let id = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        joiningIDs.insert(id)
        let joiner = joiner
        do {
            _ = try await Task.detached {
                try joiner(id)
            }.value
            joiningIDs.remove(id)
            joinsCompleted += 1
            joinError = nil
            await load()
        } catch {
            joiningIDs.remove(id)
            joinFailures += 1
            joinError = Self.message(for: error)
        }
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
