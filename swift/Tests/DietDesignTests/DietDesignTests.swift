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
        XCTAssertEqual(DietAvatar.initials(for: "Megan Harper"), "MH")
        XCTAssertEqual(DietAvatar.initials(for: "a b c"), "AB")
        XCTAssertEqual(
            DietAvatar.initials(for: "  Ava   Lindqvist "), "AL")
    }

    func testHueDeterministic() {
        let first = DietAvatar.hue(for: "Megan Harper")
        XCTAssertEqual(first, DietAvatar.hue(for: "Megan Harper"))
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

// MARK: - om-a2-labels: contrast floors

final class DietContrastTests: XCTestCase {
    private typealias RGBA = (
        r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)

    private func linear(_ c: CGFloat) -> CGFloat {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func luminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Translucent token over an opaque surface, then WCAG ratio.
    private func ratio(fg: RGBA, bg: RGBA) -> CGFloat {
        let r = fg.a * fg.r + (1 - fg.a) * bg.r
        let g = fg.a * fg.g + (1 - fg.a) * bg.g
        let b = fg.a * fg.b + (1 - fg.a) * bg.b
        let l1 = luminance(r: r, g: g, b: b)
        let l2 = luminance(r: bg.r, g: bg.g, b: bg.b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testTertiaryMeetsNonTextFloor() {
        // Tertiary is the supplementary/icon token (pin glyphs,
        // dismiss icons, separators): WCAG non-text floor 3:1 on
        // every surface it sits on, both appearances. Real text
        // uses secondary/primary instead.
        let surfaces = [
            DietColor.window, DietColor.sidebar, DietColor.card,
            DietColor.well, DietColor.bubbleIn, DietColor.bubbleOut,
        ]
        for dark in [false, true] {
            let fg = DietColor.resolved(DietColor.textTertiary, dark: dark)
            for surface in surfaces {
                let bg = DietColor.resolved(surface, dark: dark)
                XCTAssertGreaterThanOrEqual(
                    ratio(fg: fg, bg: bg), 3.0,
                    "tertiary < 3:1 (dark=\(dark))")
            }
        }
    }

    func testAvatarInitialsContrast() {
        // Initials vs avatar fill across the whole hue wheel: 4.5:1
        // everywhere (the fill keeps its hue; the initials flip to
        // dark on light fills).
        for step in 0..<100 {
            let hue = Double(step) / 100.0
            let fill = DietAvatar.fillRGB(forHue: hue)
            let dark = DietAvatar.useDarkInitials(forHue: hue)
            let t: CGFloat = dark ? 0 : 1
            let l1 = luminance(r: t, g: t, b: t)
            let l2 = luminance(r: fill.r, g: fill.g, b: fill.b)
            let r = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
            XCTAssertGreaterThanOrEqual(
                r, 4.5, "initials < 4.5:1 at hue \(hue)")
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
