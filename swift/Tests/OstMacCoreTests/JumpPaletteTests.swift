// JumpPaletteTests.swift — om-cmdk lane: fuzzy scoring, ranking, targets.
import XCTest

import OstMacChatList
import OstMacCore

final class JumpPaletteTests: XCTestCase {
    // MARK: - FuzzyMatch.score

    func testEmptyQueryScoresZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "", target: "Anything"), 0)
    }

    func testNonSubsequenceIsNil() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", target: "Design Sync"))
        XCTAssertNil(FuzzyMatch.score(query: "sync design", target: "Design Sync"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "AVA", target: "Ava Lindqvist"))
        XCTAssertNotNil(FuzzyMatch.score(query: "ava", target: "Ava Lindqvist"))
    }

    func testPrefixBeatsScattered() {
        let prefix = FuzzyMatch.score(query: "des", target: "Design Sync")!
        let scattered = FuzzyMatch.score(query: "des", target: "Ademo E S")!
        XCTAssertGreaterThan(prefix, scattered)
    }

    func testWordBoundaryBeatsMidWord() {
        // Same case + adjacency; only the boundary differs.
        let boundary = FuzzyMatch.score(query: "sync", target: "Pre sync")!
        let mid = FuzzyMatch.score(query: "sync", target: "Presync")!
        XCTAssertGreaterThan(boundary, mid)
    }

    // MARK: - FuzzyMatch.ranked

    func testEmptyQueryKeepsOrder() {
        let targets = sampleTargets()
        XCTAssertEqual(FuzzyMatch.ranked(targets, query: "  ").map(\.id), targets.map(\.id))
    }

    func testFiltersNonMatches() {
        let ranked = FuzzyMatch.ranked(sampleTargets(), query: "ava l")
        XCTAssertEqual(ranked.map(\.id), ["demo-2"])
    }

    func testQualifiedHitFindsChannelByTeam() {
        let ranked = FuzzyMatch.ranked(sampleTargets(), query: "eng ship")
        XCTAssertTrue(ranked.contains { $0.id == "demo-chan-shipping" })
    }

    func testDirectHitOutranksQualified() {
        let targets = sampleTargets()
        let ranked = FuzzyMatch.ranked(targets, query: "eng")
        XCTAssertEqual(ranked.first?.id, "demo-team-eng")
    }

    // MARK: - JumpTargets.build

    func testBuildCounts() {
        let targets = JumpTargets.build(chats: DemoData.chats, teams: DemoData.teams)
        let chats = targets.filter { $0.kind == .chat }
        let channels = targets.filter { $0.kind == .channel }
        let teams = targets.filter { $0.kind == .team }
        XCTAssertEqual(chats.count, DemoData.chats.count)
        XCTAssertEqual(channels.count, 3) // 2 eng + 1 design
        XCTAssertEqual(teams.count, 2)
    }

    func testTeamOpensFirstChannel() {
        let targets = JumpTargets.build(chats: [], teams: DemoData.teams)
        let eng = targets.first { $0.id == "demo-team-eng" }!
        XCTAssertEqual(eng.openID, "demo-chan-general")
        XCTAssertEqual(eng.openName, "Engineering > #General")
    }

    func testChannelLessTeamNotOpenable() {
        let lonely = TeamItem(teamId: "t-0", name: "Lonely", channels: [])
        let targets = JumpTargets.build(chats: [], teams: [lonely])
        XCTAssertEqual(targets.count, 1)
        XCTAssertNil(targets[0].openID)
    }

    // MARK: - jump() routing

    /// jump() routes known chat ids through the sidebar selection and
    /// everything else through open-by-id; pin the membership predicate.
    func testJumpRoutingPredicate() {
        XCTAssertTrue(DemoData.chats.contains { $0.id == DemoData.avaID })
        XCTAssertFalse(DemoData.chats.contains { $0.id == "demo-chan-general" })
    }

    private func sampleTargets() -> [JumpTarget] {
        JumpTargets.build(chats: DemoData.chats, teams: DemoData.teams)
    }
}
