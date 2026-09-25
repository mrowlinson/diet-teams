// ShiftsTests.swift — om-shifts lane: wire decode, bucketing, store open.
import XCTest

@testable import OstMacCore

@MainActor
final class ShiftsTests: XCTestCase {
    nonisolated static func weekJSON() -> ShiftWeekResponse {
        let json = """
            {"ok":true,"team_id":"team-1",\
            "schedule":{"enabled":true,"time_zone":"America/New_York",\
            "provision_status":"Completed"},\
            "shifts":[\
            {"id":"s1","user_id":"u1","display_name":"Morning",\
            "start":"2026-09-28T09:00:00","end":"2026-09-28T17:00:00",\
            "theme":"blue","notes":null,"is_draft":false},\
            {"id":"s2","user_id":"u2","display_name":"Night",\
            "start":"2026-09-29T21:00:00","end":"2026-09-30T05:00:00",\
            "theme":null,"notes":null,"is_draft":true}],\
            "times_off":[\
            {"id":"o1","user_id":"u1","reason_id":"r1",\
            "start":"2026-09-30T00:00:00","end":"2026-10-01T00:00:00",\
            "is_draft":false}],\
            "reasons":[\
            {"id":"r1","name":"Vacation","code":"V"},\
            {"id":"r2","name":"Sick","code":null}]}
            """
        return try! decodeOrThrow(ShiftWeekResponse.self, from: Data(json.utf8))
    }

    nonisolated static func weekStart() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(
            year: 2026, month: 9, day: 28, hour: 0, minute: 0))!
    }

    func waitFor(_ what: String, _ cond: @escaping () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testDecodeWeek() {
        let response = Self.weekJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.team_id, "team-1")
        XCTAssertTrue(response.schedule.enabled)
        XCTAssertEqual(response.schedule.timeZone, "America/New_York")
        XCTAssertEqual(response.shifts.count, 2)
        XCTAssertEqual(response.shifts[0].displayName, "Morning")
        XCTAssertEqual(response.shifts[0].theme, "blue")
        XCTAssertTrue(response.shifts[1].isDraft)
        XCTAssertEqual(response.timesOff.count, 1)
        XCTAssertEqual(response.reasons.count, 2)
        XCTAssertEqual(response.reasons[1].name, "Sick")
    }

    func testBucketColumns() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let week = ShiftWeek.build(
            from: Self.weekJSON(), weekStart: Self.weekStart(), calendar: cal)
        XCTAssertEqual(week.columns.count, 7)
        // s1 Monday -> column 0, s2 Tuesday -> column 1.
        XCTAssertEqual(week.columns[0].map(\.id), ["s1"])
        XCTAssertEqual(week.columns[1].map(\.id), ["s2"])
        for day in 2 ..< 7 {
            XCTAssertTrue(week.columns[day].isEmpty)
        }
    }

    func testOutOfRangeShiftsDropped() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let resp = ShiftWeekResponse(
            ok: true, team_id: "t", schedule: ShiftSchedule(enabled: true),
            shifts: [
                ShiftItem(id: "far", start: "2026-10-20T09:00:00"),
                ShiftItem(id: "bad", start: "not-a-date"),
                ShiftItem(id: "none"),
            ],
            timesOff: [], reasons: [])
        let week = ShiftWeek.build(
            from: resp, weekStart: Self.weekStart(), calendar: cal)
        XCTAssertTrue(week.columns.allSatisfy(\.isEmpty))
    }

    func testBalancesCountApprovedPerReason() {
        let resp = Self.weekJSON()
        let balances = ShiftWeek.balances(
            reasons: resp.reasons, timesOff: resp.timesOff)
        // Only r1 has an approved instance; r2 (zero) is omitted.
        XCTAssertEqual(balances.count, 1)
        XCTAssertEqual(balances[0].reason.id, "r1")
        XCTAssertEqual(balances[0].count, 1)
    }

    func testBalancesSkipDrafts() {
        let reasons = [TimeOffReason(id: "r1", name: "Vacation")]
        let offs = [TimeOffItem(id: "o9", reasonId: "r1", isDraft: true)]
        XCTAssertTrue(ShiftWeek.balances(reasons: reasons, timesOff: offs).isEmpty)
    }

    func testShiftDateParsesOffsetAndBare() {
        XCTAssertNotNil(ShiftItem.parse(dateTime: "2026-09-28T09:00:00"))
        XCTAssertNotNil(ShiftItem.parse(dateTime: "2026-09-28T09:00:00-04:00"))
        XCTAssertNil(ShiftItem.parse(dateTime: nil))
        XCTAssertNil(ShiftItem.parse(dateTime: "nope"))
    }

    func testOpenReplacesWeek() async throws {
        let resp = Self.weekJSON()
        let store = ShiftsStore(week: { _ in resp })
        store.setTeams([ShiftTeam(id: "team-1", name: "Store")])
        store.open(teamID: "team-1")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.selectedTeamID, "team-1")
        XCTAssertNotNil(store.week)
        XCTAssertEqual(store.week?.balances.count, 1)
    }

    func testOpenEmptySurfaces() async throws {
        let resp = ShiftWeekResponse(
            ok: true, team_id: "t", schedule: ShiftSchedule(enabled: true),
            shifts: [], timesOff: [], reasons: [])
        let store = ShiftsStore(week: { _ in resp })
        store.open(teamID: "team-9")
        try await waitFor("empty") { store.state == .empty }
        XCTAssertNotNil(store.week)
    }

    func testOpenErrorSurfaces() async throws {
        let store = ShiftsStore(week: { _ in
            throw CoreCallError.failed("nope")
        })
        store.open(teamID: "team-1")
        try await waitFor("error") {
            if case .error = store.state { return true }
            return false
        }
        XCTAssertNil(store.week)
    }

    func testBlankTeamIDResetsIdle() {
        let store = ShiftsStore(week: { _ in Self.weekJSON() })
        store.open(teamID: "   ")
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.week)
    }

    func testShiftsWeekWiredToCore() {
        // Blank ids are rejected by core pre-network (no stub left).
        XCTAssertThrowsError(try RustCore.shiftsWeek(teamID: "   ")) { error in
            guard case CoreCallError.failed(let m) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(m.contains("team_id"))
        }
    }
}
