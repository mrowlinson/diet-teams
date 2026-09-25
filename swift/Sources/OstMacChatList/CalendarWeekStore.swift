// CalendarWeekStore.swift — B1 calendar lane: week-grid state + schedule
// + cancel. Mirror of MeetingsViewModel seams: default runners call
// RustCore (blocking FFI) on detached tasks; tests inject mocks.
// `localEdits` (demo hosting) applies schedule/cancel in memory.
import Combine
import Foundation
import OstMacCore

/// Week-grid state machine + schedule/cancel flows for one week window.
@MainActor
public final class CalendarWeekStore: ObservableObject {
    /// Sync week fetch (runs off-main). Throws `CoreCallError` on failure.
    public typealias WeekFetcher = @Sendable (Int64) throws -> CalWeekResponse
    public typealias ScheduleRunner = @Sendable (
        String, String, String, String, Bool
    ) throws -> CalEventResult
    public typealias CancelRunner = @Sendable (String) throws -> CalCancelResult

    /// Latest meetings (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var meetings: [MeetingItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: MeetingsState = .loading
    /// Week midnight the grid covers (Monday when Monday-first).
    @Published public private(set) var weekStart: Date
    /// Selected grid day (`"yyyy-MM-dd"`); nil = today when in week.
    @Published public var selectedDayKey: String?
    /// Schedule sheet visibility.
    @Published public var showSchedule = false
    /// Schedule POST in flight.
    @Published public private(set) var scheduling = false
    /// Last schedule failure (user-facing). Nil when clear.
    @Published public private(set) var scheduleError: String?
    /// Event id with a cancel in flight (nil when idle).
    @Published public private(set) var cancelingID: String?
    /// Last cancel failure (user-facing). Nil when clear.
    @Published public private(set) var cancelError: String?

    /// Seven `"yyyy-MM-dd"` keys for the grid header row.
    public var dayKeys: [String] {
        CalWeek.dayKeys(weekStart: weekStart, calendar: calendar)
    }

    /// Meetings bucketed into the 7 grid columns.
    public var columns: [[MeetingItem]] {
        CalWeek.bucket(meetings, weekStart: weekStart, calendar: calendar)
    }

    /// Rows for the selected day (today when in week and nothing picked).
    public var selectedMeetings: [MeetingItem] {
        let keys = dayKeys
        let key: String?
        if let picked = selectedDayKey, keys.contains(picked) {
            key = picked
        } else {
            let today = dayKeyFormatter.string(from: Date())
            key = keys.contains(today) ? today : keys.first
        }
        guard let key else { return [] }
        return meetings
            .filter { CalWeek.dayKey(of: $0) == key }
            .sorted { ($0.start ?? "~") < ($1.start ?? "~") }
    }

    private let weekFetcher: WeekFetcher
    private let scheduleRunner: ScheduleRunner
    private let cancelRunner: CancelRunner
    private let calendar: Calendar
    private let localEdits: Bool
    private let dayKeyFormatter: DateFormatter

    public init(
        weekStart: Date = CalWeek.startOfWeek(containing: Date()),
        calendar: Calendar = .current,
        weekFetcher: @escaping WeekFetcher = { try RustCore.calWeek(weekStart: $0) },
        scheduleRunner: @escaping ScheduleRunner = {
            try RustCore.calSchedule(
                subject: $0, start: $1, end: $2, timeZone: $3, online: $4)
        },
        cancelRunner: @escaping CancelRunner = { try RustCore.calCancel(eventID: $0) },
        localEdits: Bool = false
    ) {
        self.weekStart = calendar.startOfDay(for: weekStart)
        self.calendar = calendar
        self.weekFetcher = weekFetcher
        self.scheduleRunner = scheduleRunner
        self.cancelRunner = cancelRunner
        self.localEdits = localEdits
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        self.dayKeyFormatter = fmt
    }

    /// Fetch the current week window.
    public func load() async {
        state = .loading
        let fetcher = weekFetcher
        let start = Int64(weekStart.timeIntervalSince1970)
        do {
            let response = try await Task.detached { try fetcher(start) }.value
            meetings = response.meetings
            state = response.meetings.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry, week paging).
    public func refresh() {
        Task { await load() }
    }

    /// Shift the window one week back and reload.
    public func prevWeek() {
        shiftWeek(by: -7)
    }

    /// Shift the window one week forward and reload.
    public func nextWeek() {
        shiftWeek(by: 7)
    }

    private func shiftWeek(by days: Int) {
        weekStart = calendar.date(byAdding: .day, value: days, to: weekStart) ?? weekStart
        refresh()
    }

    /// Schedule one meeting (`start`/`end` are Graph datetimes). Empty
    /// subjects and inverted ranges fail locally; on success the created
    /// event appends and the sheet closes.
    public func schedule(subject: String, start: String, end: String, online: Bool) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            scheduleError = "Subject is required"
            return
        }
        guard end > start else {
            scheduleError = "End must be after start"
            return
        }
        if localEdits {
            meetings.append(MeetingItem(
                meetingId: "demo-cal-local-\(meetings.count + 1)",
                subject: trimmed, start: start, end: end, isOnline: online))
            scheduleError = nil
            showSchedule = false
            if state == .empty { state = .loaded }
            return
        }
        let runner = scheduleRunner
        let timeZone = TimeZone.current.identifier
        scheduleError = nil
        scheduling = true
        Task.detached { [weak self] in
            do {
                let created = try runner(trimmed, start, end, timeZone, online)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.meetings.append(created.event)
                    self.scheduling = false
                    self.showSchedule = false
                    if self.state == .empty { self.state = .loaded }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.scheduling = false
                    self?.scheduleError = Self.message(for: error)
                }
            }
        }
    }

    /// Dismiss the schedule sheet and clear its error.
    public func dismissSchedule() {
        showSchedule = false
        scheduleError = nil
    }

    /// Cancel one meeting. On success the row drops; on failure the row
    /// stays and `cancelError` surfaces. No-op while a cancel runs.
    public func cancel(eventID: String) {
        guard cancelingID == nil else { return }
        if localEdits {
            meetings.removeAll { $0.id == eventID }
            cancelError = nil
            if meetings.isEmpty { state = .empty }
            return
        }
        let runner = cancelRunner
        cancelError = nil
        cancelingID = eventID
        Task.detached { [weak self] in
            do {
                _ = try runner(eventID)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.meetings.removeAll { $0.id == eventID }
                    self.cancelingID = nil
                    if self.meetings.isEmpty { self.state = .empty }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.cancelingID = nil
                    self?.cancelError = Self.message(for: error)
                }
            }
        }
    }

    nonisolated static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
