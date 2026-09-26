// PollTimersHoldPinsTests — om-perf-poll-timers: pin the audit HOLDS so the
// timer/poll wins can't silently regress. Behavioral where cheap (feed
// loop), static where the win lives in app wiring (2s tick gate).
import XCTest
@testable import OstMacCore

final class PollTimersHoldPinsTests: XCTestCase {
    /// Live feed = blocking-wait chain: start() drains once via poll, then
    /// loops on pollWait. The 1s timer must stay idle (fallback only).
    func testStartUsesBlockingWaitChain() {
        final class Counters: @unchecked Sendable {
            private let lock = NSLock()
            private var _polls = 0
            private var _waits = 0
            func bumpPoll() { lock.lock(); _polls += 1; lock.unlock() }
            func bumpWait() { lock.lock(); _waits += 1; lock.unlock() }
            var polls: Int { lock.lock(); defer { lock.unlock() }; return _polls }
            var waits: Int { lock.lock(); defer { lock.unlock() }; return _waits }
        }
        let c = Counters()
        let empty = RealtimePoll(ok: true, messages: [], resync: false, skipped: 0)
        let feed = RealtimeFeed(
            poll: { c.bumpPoll(); return empty },
            pollWait: { _ in c.bumpWait(); return empty },
            start: { 0 }, stop: { 0 })
        feed.pollInterval = 60 // timer armed-but-idle; must never fire here
        feed.start()
        XCTAssertEqual(feed.currentState, .live)
        let end = Date().addingTimeInterval(2)
        while c.waits < 2, Date() < end {
            Thread.sleep(forTimeInterval: 0.02)
        }
        feed.stop()
        XCTAssertGreaterThanOrEqual(c.waits, 2, "live loop must chain pollWait")
        XCTAssertEqual(c.polls, 1, "poll runs once (initial drain); timer stays idle")
    }

    /// The App 2s tick must stay gated on visible surfaces (else the root
    /// re-evals every 2s while hidden/miniaturized).
    func testAppTickGatedOnVisibleSurfaces() throws {
        let here = URL(fileURLWithPath: #filePath)
        let app = here
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // OstMacCoreTests dir
            .deletingLastPathComponent() // Tests dir → swift dir
            .appendingPathComponent("Sources/OstMac/App.swift")
        let body = try String(contentsOf: app, encoding: .utf8)
        XCTAssertTrue(body.contains("private func tick()"), "tick() moved?")
        let gate = "guard Self.surfacesVisible() else { return }"
        XCTAssertEqual(
            body.components(separatedBy: gate).count - 1, 1,
            "tick() must keep its surfacesVisible early-return (exactly one use)")
    }
}
