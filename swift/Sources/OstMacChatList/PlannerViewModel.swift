// PlannerViewModel.swift — loads Planner boards via PlannerCore.
import Combine
import Foundation
import OstMacCore

/// Teams content state (mirrors RemindersState).
public enum PlannerState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty teams in `teams`.
    case loaded
    /// Fetch succeeded with zero teams.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads joined teams off the main thread, owns team selection, the
/// selected team's plans, and the selected plan's buckets + tasks.
/// Default fetchers call `RustCore.teams` / `PlannerCore.*` (blocking
/// FFI + network) on detached tasks. Tests inject mock fetchers.
/// `localEdits` (demo mode) applies add/complete/reopen to the
/// in-memory rows instead of calling core, so `--demo` stays offline.
@MainActor
public final class PlannerViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias TeamsFetcher = @Sendable () throws -> TeamsResponse
    public typealias PlansFetcher = @Sendable (String) throws -> PlannerPlansResponse
    public typealias BucketsFetcher = @Sendable (String) throws -> PlannerBucketsResponse
    public typealias TasksFetcher = @Sendable (String) throws -> PlannerTasksResponse
    public typealias AddFetcher = @Sendable (String, String, String) throws -> PlannerTaskResult
    public typealias SetFetcher = @Sendable (String, String) throws -> PlannerTaskResult

    /// Latest teams (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var teams: [TeamItem] = []
    /// Current teams state. Starts `.loading`.
    @Published public private(set) var state: PlannerState = .loading
    /// Selected team id (first team after load; nil when empty).
    @Published public private(set) var selectedTeamID: String?
    /// Plans of the selected team.
    @Published public private(set) var plans: [PlannerPlan] = []
    /// Selected plan id (first plan after plans load; nil when empty).
    @Published public private(set) var selectedPlanID: String?
    /// Buckets of the selected plan.
    @Published public private(set) var buckets: [PlannerBucket] = []
    /// Tasks of the selected plan (across all buckets).
    @Published public private(set) var tasks: [PlannerTask] = []
    /// Plans/buckets/tasks fetch in flight.
    @Published public private(set) var boardLoading = false
    /// Last board/add/complete/reopen failure (user-facing); nil when clear.
    @Published public private(set) var boardError: String?

    private let teamsFetcher: TeamsFetcher
    private let plansFetcher: PlansFetcher
    private let bucketsFetcher: BucketsFetcher
    private let tasksFetcher: TasksFetcher
    private let addFetcher: AddFetcher
    private let doneFetcher: SetFetcher
    private let reopenFetcher: SetFetcher
    private let localEdits: Bool

    public init(
        teamsFetcher: @escaping TeamsFetcher = { try RustCore.teams() },
        plansFetcher: @escaping PlansFetcher = { try PlannerCore.plans(groupID: $0) },
        bucketsFetcher: @escaping BucketsFetcher = { try PlannerCore.buckets(planID: $0) },
        tasksFetcher: @escaping TasksFetcher = { try PlannerCore.tasks(planID: $0) },
        addFetcher: @escaping AddFetcher = { try PlannerCore.add(planID: $0, bucketID: $1, title: $2) },
        doneFetcher: @escaping SetFetcher = { try PlannerCore.done(taskID: $0, etag: $1) },
        reopenFetcher: @escaping SetFetcher = { try PlannerCore.reopen(taskID: $0, etag: $1) },
        localEdits: Bool = false
    ) {
        self.teamsFetcher = teamsFetcher
        self.plansFetcher = plansFetcher
        self.bucketsFetcher = bucketsFetcher
        self.tasksFetcher = tasksFetcher
        self.addFetcher = addFetcher
        self.doneFetcher = doneFetcher
        self.reopenFetcher = reopenFetcher
        self.localEdits = localEdits
    }

    /// Fetch teams, select the first, fetch its plans + first board.
    public func load() async {
        state = .loading
        boardError = nil
        let fetcher = teamsFetcher
        do {
            let response = try await Task.detached {
                try fetcher()
            }.value
            teams = response.teams
            state = response.teams.isEmpty ? .empty : .loaded
            selectedTeamID = response.teams.first?.teamId
            if let id = selectedTeamID {
                await loadPlans(teamID: id)
            } else {
                clearBoard()
            }
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry, sign-in).
    public func refresh() {
        Task { await load() }
    }

    /// Select another team and fetch its plans + first board.
    public func selectTeam(teamID: String) {
        guard teamID != selectedTeamID else { return }
        selectedTeamID = teamID
        Task { await loadPlans(teamID: teamID) }
    }

    /// Select another plan and fetch its board.
    public func selectPlan(planID: String) {
        guard planID != selectedPlanID else { return }
        selectedPlanID = planID
        Task { await loadBoard(planID: planID) }
    }

    /// Refresh the selected plan's board.
    public func refreshBoard() {
        guard let id = selectedPlanID else { return }
        Task { await loadBoard(planID: id) }
    }

    /// Tasks in one bucket, newest last (optionally hiding completed).
    public nonisolated static func visible(
        _ tasks: [PlannerTask], bucketID: String, hideDone: Bool
    ) -> [PlannerTask] {
        tasks.filter {
            $0.bucketId == bucketID && (!hideDone || !$0.completed)
        }
    }

    /// Tasks whose bucket is unknown (defensive: never silently drop rows
    /// when the buckets call lags the tasks call).
    public nonisolated static func orphaned(
        _ tasks: [PlannerTask], buckets: [PlannerBucket]
    ) -> [PlannerTask] {
        let known = Set(buckets.map(\.bucketId))
        return tasks.filter { !known.contains($0.bucketId) }
    }

    /// Add a task to one bucket of the selected plan. Empty titles and
    /// unknown buckets are ignored.
    public func add(bucketID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let planID = selectedPlanID,
              buckets.contains(where: { $0.bucketId == bucketID })
        else { return }
        if localEdits {
            tasks.append(PlannerTask(
                taskId: "demo-ptask-local-\(tasks.count + 1)",
                planId: planID, bucketId: bucketID, title: trimmed))
            boardError = nil
            return
        }
        let fetcher = addFetcher
        boardError = nil
        Task.detached { [weak self] in
            do {
                let created = try fetcher(planID, bucketID, trimmed)
                await MainActor.run { [weak self] in
                    self?.tasks.append(created.task)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Mark a task completed (100). No-op when already done. The row's
    /// etag feeds `If-Match`; a 412 surfaces in `boardError`.
    public func complete(taskID: String) {
        set(taskID: taskID, complete: true)
    }

    /// Reopen a task (0). No-op when not done.
    public func reopen(taskID: String) {
        set(taskID: taskID, complete: false)
    }

    private func set(taskID: String, complete: Bool) {
        guard let idx = tasks.firstIndex(where: { $0.taskId == taskID }),
              tasks[idx].completed != complete
        else { return }
        if localEdits {
            let row = tasks[idx]
            tasks[idx] = PlannerTask(
                taskId: row.taskId, planId: row.planId,
                bucketId: row.bucketId, title: row.title,
                percent: complete ? 100 : 0, completed: complete,
                priority: row.priority, due: row.due, etag: row.etag)
            return
        }
        let fetcher = complete ? doneFetcher : reopenFetcher
        let etag = tasks[idx].etag
        boardError = nil
        Task.detached { [weak self] in
            do {
                let updated = try fetcher(taskID, etag)
                await MainActor.run { [weak self] in
                    guard let self,
                          let i = self.tasks.firstIndex(where: { $0.taskId == taskID })
                    else { return }
                    self.tasks[i] = updated.task
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    private func loadPlans(teamID: String) async {
        boardLoading = true
        boardError = nil
        clearBoard(keepLoading: true)
        let fetcher = plansFetcher
        do {
            let response = try await Task.detached {
                try fetcher(teamID)
            }.value
            // Selection may have moved while fetching; only adopt when fresh.
            if teamID == selectedTeamID {
                plans = response.plans
                selectedPlanID = response.plans.first?.planId
                if let planID = selectedPlanID {
                    await loadBoard(planID: planID)
                    return
                }
            }
        } catch {
            if teamID == selectedTeamID {
                boardError = Self.message(for: error)
            }
        }
        if teamID == selectedTeamID {
            boardLoading = false
        }
    }

    private func loadBoard(planID: String) async {
        boardLoading = true
        boardError = nil
        let bFetcher = bucketsFetcher
        let tFetcher = tasksFetcher
        do {
            async let bResponse = Task.detached {
                try bFetcher(planID)
            }.value
            async let tResponse = Task.detached {
                try tFetcher(planID)
            }.value
            let (buckets, tasks) = try await (bResponse, tResponse)
            // Selection may have moved while fetching; only adopt when fresh.
            if planID == selectedPlanID {
                self.buckets = buckets.buckets
                self.tasks = tasks.tasks
            }
        } catch {
            if planID == selectedPlanID {
                boardError = Self.message(for: error)
            }
        }
        if planID == selectedPlanID {
            boardLoading = false
        }
    }

    private func clearBoard(keepLoading: Bool = false) {
        plans = []
        selectedPlanID = nil
        buckets = []
        tasks = []
        if !keepLoading {
            boardLoading = false
        }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
