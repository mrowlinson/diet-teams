// ReskinChatTests.swift — om-reskin-chat: presence mapping, sidebar
// sections, jump-palette sizing (pure helpers behind the reskin).
import DietDesign
import XCTest

@testable import OstMacChatList
@testable import OstMacCore

final class ReskinChatTests: XCTestCase {
    // MARK: - Teams availability → DietPresence

    func testPresenceMappingKnown() {
        XCTAssertEqual(DietPresence(teamsAvailability: "Available"), .available)
        XCTAssertEqual(DietPresence(teamsAvailability: "Busy"), .busy)
        XCTAssertEqual(DietPresence(teamsAvailability: "DoNotDisturb"), .dnd)
        XCTAssertEqual(DietPresence(teamsAvailability: "Away"), .away)
        XCTAssertEqual(DietPresence(teamsAvailability: "BeRightBack"), .away)
        XCTAssertEqual(DietPresence(teamsAvailability: "Offline"), .offline)
    }

    func testPresenceMappingUnknownFailsClosed() {
        XCTAssertNil(DietPresence(teamsAvailability: nil))
        XCTAssertNil(DietPresence(teamsAvailability: "PresenceUnknown"))
        XCTAssertNil(DietPresence(teamsAvailability: "FutureValue"))
        XCTAssertNil(DietPresence(teamsAvailability: ""))
    }

    // MARK: - Sidebar sections

    func testSidebarSectionLabels() {
        XCTAssertEqual(
            SidebarSection.allCases.map(\.rawValue),
            ["Chats", "Teams", "Reminders", "Planner", "Recordings", "Shifts"])
    }

    // MARK: - Jump palette list height

    func testPaletteHeightGrowsWithMatches() {
        let one = JumpPaletteView.listHeight(for: 1)
        let three = JumpPaletteView.listHeight(for: 3)
        XCTAssertGreaterThan(three, one)
        XCTAssertEqual(three, 3 * DietSize.sidebarRow + DietSpace.sm)
    }

    func testPaletteHeightClamps() {
        XCTAssertEqual(JumpPaletteView.listHeight(for: 0), 120)
        XCTAssertEqual(JumpPaletteView.listHeight(for: 100), 320)
    }
}
