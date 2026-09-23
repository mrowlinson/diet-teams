// SidebarAnimTests.swift — om-sidebar-anim: Teams expand/collapse state
// helpers (pure logic behind the DisclosureGroup bindings). The chevron
// animation itself is the system DisclosureGroup + .animation(.default),
// verified visually via docs/shots (om-sidebar-anim-*).
import XCTest

@testable import OstMacChatList

final class SidebarAnimTests: XCTestCase {
    // MARK: - isExpanded

    func testExpandedByDefault() {
        XCTAssertTrue(
            TeamsBrowser.isExpanded(teamID: "t1", collapsed: [], filtering: false))
    }

    func testCollapsedTeamStaysCollapsed() {
        XCTAssertFalse(
            TeamsBrowser.isExpanded(teamID: "t1", collapsed: ["t1"], filtering: false))
    }

    func testOtherTeamsUnaffected() {
        XCTAssertTrue(
            TeamsBrowser.isExpanded(teamID: "t2", collapsed: ["t1"], filtering: false))
    }

    func testFilteringPinsCollapsedOpen() {
        // Matches must never hide inside a collapsed group.
        XCTAssertTrue(
            TeamsBrowser.isExpanded(teamID: "t1", collapsed: ["t1"], filtering: true))
    }

    func testFilteringKeepsOpenOpen() {
        XCTAssertTrue(
            TeamsBrowser.isExpanded(teamID: "t1", collapsed: [], filtering: true))
    }

    // MARK: - toggled

    func testToggleCollapsesExpanded() {
        XCTAssertEqual(TeamsBrowser.toggled([], teamID: "t1"), ["t1"])
    }

    func testToggleExpandsCollapsed() {
        XCTAssertEqual(TeamsBrowser.toggled(["t1"], teamID: "t1"), [])
    }

    func testToggleIsPerTeam() {
        XCTAssertEqual(
            TeamsBrowser.toggled(["t1"], teamID: "t2"), ["t1", "t2"])
    }

    func testToggleTwiceRestores() {
        let once = TeamsBrowser.toggled([], teamID: "t1")
        XCTAssertEqual(TeamsBrowser.toggled(once, teamID: "t1"), [])
    }

    func testTogglePreservesOthers() {
        XCTAssertEqual(
            TeamsBrowser.toggled(["t1", "t2"], teamID: "t1"), ["t2"])
    }
}
