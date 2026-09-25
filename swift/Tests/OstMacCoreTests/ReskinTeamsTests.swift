// ReskinTeamsTests.swift — om-reskin-teams: channel display names,
// sidebar sections, team avatar inputs (pure helpers behind the reskin).
import DietDesign
import XCTest

@testable import OstMacChatList
@testable import OstMacCore

final class ReskinTeamsTests: XCTestCase {
    // MARK: - Channel display names

    func testChannelDisplayNameFormat() {
        XCTAssertEqual(
            TeamsBrowser.channelDisplayName(team: "Engineering", channel: "General"),
            "Engineering > #General")
    }

    func testChannelDisplayNameMatchesDemoData() {
        // The browser's onOpen name and DemoData.name must agree so the
        // opened channel header shows the same title in demo + live.
        for team in DemoData.teams {
            for channel in team.channels {
                XCTAssertEqual(
                    TeamsBrowser.channelDisplayName(team: team.name, channel: channel.name),
                    DemoData.name(for: channel.id))
            }
        }
    }

    // MARK: - Sidebar sections

    func testSidebarSectionLabels() {
        XCTAssertEqual(
            SidebarSection.allCases.map(\.rawValue),
            ["Chats", "Teams", "Reminders", "Recordings"])
    }

    // MARK: - Team header avatar inputs

    func testTeamAvatarInitials() {
        XCTAssertEqual(DietAvatar.initials(for: "Engineering"), "EN")
        XCTAssertEqual(DietAvatar.initials(for: "Design"), "DE")
        XCTAssertEqual(DietAvatar.initials(for: ""), "?")
    }

    func testTeamAvatarHueDeterministic() {
        XCTAssertEqual(
            DietAvatar.hue(for: "Engineering"),
            DietAvatar.hue(for: "Engineering"))
        let hue = DietAvatar.hue(for: "Design")
        XCTAssertGreaterThanOrEqual(hue, 0.0)
        XCTAssertLessThan(hue, 1.0)
    }
}
