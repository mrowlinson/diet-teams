// MessageDensityTests.swift — f2-density: message-density options.
//
// Density is spacing only: Comfortable resolves to today's exact
// constants (pinned against DietSpace/DietSize so any drift fails),
// Compact tightens gaps/padding/avatar. Persistence is one raw-string
// key in a suite-injectable store (GhostStore precedent).
import DietDesign
import XCTest

@testable import OstMacCore

@MainActor
final class MessageDensityTests: XCTestCase {
    private func densityDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-density-\(UUID().uuidString)") ?? .standard
    }

    // MARK: - default + raw mapping (accept 1)

    func testFreshInstallDefaultsToComfortable() {
        let store = DensityStore(defaults: densityDefaults())
        XCTAssertEqual(store.mode, .comfortable)
    }

    func testUnknownRawFallsBackToComfortable() {
        let defaults = densityDefaults()
        defaults.set("triple-decker", forKey: DensityStore.modeKey)
        XCTAssertEqual(DensityStore(defaults: defaults).mode, .comfortable)
    }

    func testAllCasesAreComfortableAndCompact() {
        XCTAssertEqual(MessageDensity.allCases, [.comfortable, .compact])
        XCTAssertEqual(MessageDensity.comfortable.displayName, "Comfortable")
        XCTAssertEqual(MessageDensity.compact.displayName, "Compact")
    }

    // MARK: - persistence (accept 4)

    func testModePersistsRawString() {
        let defaults = densityDefaults()
        let store = DensityStore(defaults: defaults)
        store.mode = .compact
        XCTAssertEqual(defaults.string(forKey: DensityStore.modeKey), "compact")
        store.mode = .comfortable
        XCTAssertEqual(defaults.string(forKey: DensityStore.modeKey), "comfortable")
    }

    func testRebuildOnSameSuiteRestoresMode() {
        let defaults = densityDefaults()
        DensityStore(defaults: defaults).mode = .compact
        XCTAssertEqual(DensityStore(defaults: defaults).mode, .compact)
    }

    func testSuitesAreIsolatedFromEachOther() {
        let a = densityDefaults()
        let b = densityDefaults()
        DensityStore(defaults: a).mode = .compact
        XCTAssertEqual(DensityStore(defaults: b).mode, .comfortable)
    }

    func testWritesNeverTouchStandardDefaults() {
        let before = UserDefaults.standard.object(
            forKey: DensityStore.modeKey) as? String
        let store = DensityStore(defaults: densityDefaults())
        store.mode = .compact
        store.mode = .comfortable
        let after = UserDefaults.standard.object(
            forKey: DensityStore.modeKey) as? String
        XCTAssertEqual(after, before)
    }

    // MARK: - spacing map (accepts 2, 3)

    func testComfortableMapIsTodaysConstants() {
        let m = MessageDensity.comfortable.metrics
        XCTAssertEqual(m.rowGap, DietSpace.sm)
        XCTAssertEqual(m.bubblePad, DietSpace.sm + DietSpace.xs)
        XCTAssertEqual(m.separatorPad, DietSpace.xs)
        XCTAssertEqual(m.sidebarRowPad, DietSpace.xs)
        XCTAssertEqual(m.avatarSize, DietSize.avatarMD)
        XCTAssertEqual(m.timelineEdge, DietSpace.md)
    }

    func testComfortableMapLiteralPin() {
        // Pixel-identical-to-today pin (accept 6): literals, so a
        // token-value change fails here instead of silently shifting
        // the default layout.
        let m = MessageDensity.comfortable.metrics
        XCTAssertEqual(m.rowGap, 8)
        XCTAssertEqual(m.bubblePad, 12)
        XCTAssertEqual(m.separatorPad, 4)
        XCTAssertEqual(m.sidebarRowPad, 4)
        XCTAssertEqual(m.avatarSize, 32)
        XCTAssertEqual(m.timelineEdge, 16)
    }

    func testCompactMapTightensSpacingOnly() {
        let m = MessageDensity.compact.metrics
        XCTAssertEqual(m.rowGap, 4)
        XCTAssertEqual(m.bubblePad, 8)
        XCTAssertEqual(m.separatorPad, 2)
        XCTAssertEqual(m.sidebarRowPad, 2)
        XCTAssertEqual(m.avatarSize, 24)
        // The content frame is untouched — rows tighten, edges don't.
        XCTAssertEqual(m.timelineEdge, 16)
    }

    func testCompactMapResolvesFromTokens() {
        let m = MessageDensity.compact.metrics
        XCTAssertEqual(m.rowGap, DietSpace.xs)
        XCTAssertEqual(m.bubblePad, DietSpace.sm)
        XCTAssertEqual(m.separatorPad, DietSpace.xxs)
        XCTAssertEqual(m.sidebarRowPad, DietSpace.xxs)
        XCTAssertEqual(m.avatarSize, DietSize.avatarSM)
        XCTAssertEqual(m.timelineEdge, DietSpace.md)
    }
}
