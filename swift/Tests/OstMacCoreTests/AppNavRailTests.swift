// AppNavRailTests.swift — app-nav lane: Teams-like rail replaces the
// 7-tab section bar; narrow-window left-clip regression.
import AppKit
import XCTest

import OstMacChatList

/// Rail layout math + section catalog. Failing-first for the section-bar
/// → rail replacement (R8 app-nav lane).
final class AppNavRailTests: XCTestCase {
    /// All 8 sections ship in the rail, in stable order.
    func testRailHostsAllEightSections() {
        XCTAssertEqual(
            SidebarSection.allCases.map(\.rawValue),
            ["Chats", "Teams", "Contacts", "Reminders", "Planner",
             "Recordings", "Transcripts", "Shifts"])
    }

    /// Rail rows track the enum, so future E/F surfaces appear with no
    /// rail change (data-driven over allCases).
    func testRailRowsAreDataDriven() {
        XCTAssertEqual(AppNavLayout.rows().count, SidebarSection.allCases.count)
        XCTAssertGreaterThanOrEqual(AppNavLayout.rows().count, 7)
    }

    /// Every section has a distinct, resolvable SF Symbol (typo guard —
    /// NSImage lookup runs on the macOS 14+ deployment target).
    func testEverySectionHasUniqueResolvableSymbol() {
        let symbols = SidebarSection.allCases.map(\.systemImage)
        XCTAssertEqual(Set(symbols).count, symbols.count, "dup symbol")
        for section in SidebarSection.allCases {
            XCTAssertFalse(
                section.systemImage.isEmpty, "\(section.rawValue) symbol empty")
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: section.systemImage,
                    accessibilityDescription: section.rawValue),
                "\(section.rawValue) symbol unresolvable")
        }
    }

    /// Section ids survive a raw-value round trip (persistence/menu safe).
    func testSectionRawValueRoundTrip() {
        for section in SidebarSection.allCases {
            XCTAssertEqual(SidebarSection(rawValue: section.rawValue), section)
        }
    }

    /// Narrow-clip regression: the old 7-segment NSSegmentedControl
    /// needed ~480pt of intrinsic width inside a 240pt column, forcing
    /// the sidebar VStack wider than its column — content overflowed
    /// ~30px left of the window edge at small sizes (base-narrow shot).
    /// The rail is fixed-width; rail + a usable browser floor must fit
    /// the column minimum.
    func testRailPlusBrowserFitsColumnMinimum() {
        XCTAssertLessThanOrEqual(
            AppNavLayout.railWidth + AppNavLayout.minBrowserWidth,
            AppNavLayout.sidebarMinWidth)
    }

    /// 9 sections (7 + future E/F) stack inside the minimum window
    /// height with no scroll.
    func testNineSectionsFitMinWindowHeight() {
        XCTAssertLessThanOrEqual(
            AppNavLayout.stackHeight(sectionCount: 9),
            AppNavLayout.minWindowHeight - AppNavLayout.chromeHeight)
    }
}
