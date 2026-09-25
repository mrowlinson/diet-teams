// ShiftsFullTests.swift — R10 shifts-fullwidth: shifts takes the whole
// window outside the app rail; the chat viewport hides while selected
// and back-nav restores it. RootView reads `takesFullWindow` only.
import XCTest

import OstMacChatList

/// Full-window routing predicates. Failing-first for the squeezed
/// chat-list-column layout → full-width shifts module replacement.
final class ShiftsFullTests: XCTestCase {
    /// Shifts selection shows the full-width view.
    func testShiftsTakesFullWindow() {
        XCTAssertTrue(SidebarSection.shifts.takesFullWindow)
    }

    /// Every other section keeps the split view (chat viewport visible).
    func testOnlyShiftsTakesFullWindow() {
        for section in SidebarSection.allCases where section != .shifts {
            XCTAssertFalse(
                section.takesFullWindow, "\(section.rawValue) must not go full")
        }
    }

    /// --show-shifts lands on the full-width view at launch.
    func testShowShiftsFlagSelectsShifts() {
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--demo", "--show-shifts"]),
            .shifts)
    }

    /// No flag → chats (unchanged default).
    func testDefaultSectionIsChats() {
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--demo"]), .chats)
    }

    /// Pre-existing shot-hook mappings survive the move (order: shifts
    /// first, then recordings/transcripts/planner/reminders/teams).
    func testExistingFlagMappingsPreserved() {
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--show-teams"]), .teams)
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--show-reminders"]),
            .reminders)
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--show-planner"]),
            .planner)
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--show-recordings"]),
            .recordings)
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--show-transcripts"]),
            .transcripts)
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--show-channel-create"]),
            .teams)
        XCTAssertEqual(
            SidebarSection.initialSection(args: ["app", "--show-team-create"]),
            .teams)
    }

    /// Back-nav restores the split view: flipping shifts → chats clears
    /// the full-window predicate (openChatID is untouched — AppState
    /// keeps it, so the conversation reappears as-is).
    func testBackNavRestoresSplitView() {
        var section = SidebarSection.shifts
        XCTAssertTrue(section.takesFullWindow)
        section = .chats
        XCTAssertFalse(section.takesFullWindow)
    }

    /// Full-window layout keeps the rail visible: the rail still lists
    /// every section (back-nav target present while shifts is full).
    func testRailStillListsAllSectionsForBackNav() {
        XCTAssertEqual(AppNavLayout.rows().count, SidebarSection.allCases.count)
        XCTAssertTrue(AppNavLayout.rows().contains(.chats))
    }
}
