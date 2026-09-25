// ShiftsStore.swift — om-shifts lane: schedule week store (read-only).
//
// Team picker + week grid state over one core call per team. Tests and
// demo inject a mock week fetcher (same seam as ChannelTabsStore).
// The default fetcher hits `ostmac_schedule_week` (wired at B1 merge).
import COstMac
import Combine
import Foundation

/// Schedule-week content state.
public enum ShiftsState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
}

extension RustCore {
    /// One team's schedule week (blocking FFI + network: call off the
    /// main thread).
    public static func shiftsWeek(teamID: String) throws -> ShiftWeekResponse {
        try teamID.withCString { ptr in
            try call(ostmac_schedule_week(ptr), as: ShiftWeekResponse.self)
        }
    }
}

@MainActor
public final class ShiftsStore: ObservableObject {
    public typealias WeekFetcher = @Sendable (String) throws -> ShiftWeekResponse

    @Published public private(set) var teams: [ShiftTeam] = []
    @Published public private(set) var selectedTeamID: String?
    @Published public private(set) var week: ShiftWeek?
    @Published public private(set) var state: ShiftsState = .idle

    private let weekFetcher: WeekFetcher
    private var openGeneration = 0

    public nonisolated init(
        week: @escaping WeekFetcher = { try RustCore.shiftsWeek(teamID: $0) }
    ) {
        self.weekFetcher = week
    }

    /// Week start for the grid (Monday 00:00 local by default).
    public static func currentWeekStart(calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return cal.date(from: comps) ?? cal.startOfDay(for: Date())
    }

    /// Seed the team picker (host passes joined teams).
    public func setTeams(_ teams: [ShiftTeam]) {
        self.teams = teams
        if selectedTeamID == nil {
            selectedTeamID = teams.first?.id
        }
    }

    /// Pick a team and fetch its week.
    public func select(teamID: String) {
        selectedTeamID = teamID
        open(teamID: teamID)
    }

    /// Open a team: fetch its week via core, replace the grid. Stale
    /// completions are dropped (fast team-switching lands newest).
    public func open(teamID: String) {
        openGeneration += 1
        let gen = openGeneration
        let id = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            selectedTeamID = nil
            week = nil
            state = .idle
            return
        }
        selectedTeamID = id
        state = .loading
        Task {
            let fetcher = weekFetcher
            do {
                let resp = try await Task.detached { try fetcher(id) }.value
                guard gen == openGeneration else { return }
                let built = ShiftWeek.build(
                    from: resp, weekStart: Self.currentWeekStart())
                week = built
                let hasRows = built.columns.contains { !$0.isEmpty } || !built.timeOff.isEmpty
                state = hasRows ? .loaded : .empty
            } catch {
                guard gen == openGeneration else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Fire-and-forget reload.
    public func refresh() {
        guard let id = selectedTeamID else { return }
        open(teamID: id)
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
