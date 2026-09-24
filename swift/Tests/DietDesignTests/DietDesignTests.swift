// DietDesignTests — token + component behavior. Appearance
// resolution pins light/dark without snapshot images.
import XCTest
@testable import DietDesign

final class DietSpaceTests: XCTestCase {
    func testGridSteps() {
        // 8pt grid: every step above xs is a multiple of 8.
        for value in [
            DietSpace.sm, DietSpace.md, DietSpace.lg, DietSpace.xl,
            DietSpace.xxl, DietSpace.row, DietSpace.section,
            DietSpace.edge, DietSize.toolbar,
        ] {
            XCTAssertEqual(
                value.truncatingRemainder(dividingBy: 8), 0,
                "\(value) breaks the 8pt grid")
        }
        XCTAssertEqual(DietSpace.xs, 4)
        XCTAssertEqual(DietSpace.xxs, 2)
    }

    func testRadiusOrdering() {
        XCTAssertLessThan(DietRadius.control, DietRadius.card)
        XCTAssertLessThan(DietRadius.card, DietRadius.bubble)
    }

    func testSizesPositive() {
        for value in [
            DietSize.iconSM, DietSize.iconMD, DietSize.iconLG,
            DietSize.iconXL, DietSize.avatarSM, DietSize.avatarMD,
            DietSize.avatarLG, DietSize.presenceDot,
            DietSize.controlHeight, DietSize.sidebarRow,
        ] {
            XCTAssertGreaterThan(value, 0)
        }
    }
}

final class DietColorTests: XCTestCase {
    private func luminance(
        _ c: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    ) -> CGFloat {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    func testLightDarkDiffer() {
        // Every surface token resolves differently per appearance.
        for color in [
            DietColor.window, DietColor.sidebar, DietColor.card,
            DietColor.well, DietColor.bubbleOut, DietColor.bubbleIn,
            DietColor.textPrimary, DietColor.textSecondary,
            DietColor.textTertiary,
        ] {
            let light = DietColor.resolved(color, dark: false)
            let dark = DietColor.resolved(color, dark: true)
            let delta = abs(luminance(light) - luminance(dark))
            XCTAssertGreaterThan(
                delta, 0.05, "token does not adapt to dark mode")
        }
    }

    func testTextContrastDirection() {
        // Light mode: dark text on light window; dark mode: inverse.
        let lightText = luminance(
            DietColor.resolved(DietColor.textPrimary, dark: false))
        let lightBg = luminance(
            DietColor.resolved(DietColor.window, dark: false))
        XCTAssertLessThan(lightText, lightBg)
        let darkText = luminance(
            DietColor.resolved(DietColor.textPrimary, dark: true))
        let darkBg = luminance(
            DietColor.resolved(DietColor.window, dark: true))
        XCTAssertGreaterThan(darkText, darkBg)
    }

    func testDividerIsHairlineWash() {
        let light = DietColor.resolved(DietColor.divider, dark: false)
        let dark = DietColor.resolved(DietColor.divider, dark: true)
        XCTAssertGreaterThan(light.a, 0)
        XCTAssertLessThan(light.a, 0.3)
        XCTAssertGreaterThan(dark.a, 0)
        XCTAssertLessThan(dark.a, 0.3)
        // Light divider is dark ink, dark divider is light ink.
        XCTAssertLessThan(luminance(light), 0.5)
        XCTAssertGreaterThan(luminance(dark), 0.5)
    }
}

final class DietTypeTests: XCTestCase {
    func testScaleComplete() {
        XCTAssertEqual(DietType.scale.count, 11)
        let names = DietType.scale.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }
}

final class DietAvatarTests: XCTestCase {
    func testInitials() {
        XCTAssertEqual(DietAvatar.initials(for: ""), "?")
        XCTAssertEqual(DietAvatar.initials(for: "Jo"), "JO")
        XCTAssertEqual(DietAvatar.initials(for: "Priya Nair"), "PN")
        XCTAssertEqual(DietAvatar.initials(for: "a b c"), "AB")
        XCTAssertEqual(
            DietAvatar.initials(for: "  Ava   Lindqvist "), "AL")
    }

    func testHueDeterministic() {
        let first = DietAvatar.hue(for: "Priya Nair")
        XCTAssertEqual(first, DietAvatar.hue(for: "Priya Nair"))
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertLessThan(first, 1)
    }
}

final class DietPresenceTests: XCTestCase {
    func testAllCasesLabeled() {
        XCTAssertEqual(DietPresence.allCases.count, 5)
        for status in DietPresence.allCases {
            XCTAssertFalse(status.label.isEmpty)
            XCTAssertFalse(status.systemImage.isEmpty)
        }
    }
}

final class DietBannerStyleTests: XCTestCase {
    func testStylesMapped() {
        for style in [
            DietBannerStyle.info, .success, .warning, .error,
        ] {
            XCTAssertFalse(style.systemImage.isEmpty)
        }
    }
}

// DietMotionTests — om-a1-motion: Reduce Motion gate contract.
final class DietMotionTests: XCTestCase {
    func testGatedNilUnderReduceMotion() {
        XCTAssertNil(DietMotion.gated(reduceMotion: true))
    }

    func testGatedPassesBaseOtherwise() {
        XCTAssertNotNil(DietMotion.gated(reduceMotion: false))
    }

    func testScrollNeverAnimatesUnderReduceMotion() {
        XCTAssertFalse(
            DietMotion.scrollAnimated(requested: true, reduceMotion: true))
        XCTAssertFalse(
            DietMotion.scrollAnimated(requested: false, reduceMotion: true))
    }

    func testScrollFollowsRequestOtherwise() {
        XCTAssertTrue(
            DietMotion.scrollAnimated(requested: true, reduceMotion: false))
        XCTAssertFalse(
            DietMotion.scrollAnimated(requested: false, reduceMotion: false))
    }
}
