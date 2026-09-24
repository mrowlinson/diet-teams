// DietColor.swift — semantic color tokens, light + dark.
// Dynamic NSColors so AppKit/SwiftUI resolve per-appearance.
import AppKit
import SwiftUI

/// Semantic palette. Every color carries explicit light/dark RGB so
/// both appearances are pinned and testable (no "looks fine" drift).
public enum DietColor {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(
            name: nil,
            dynamicProvider: { appearance in
                let darkMode = appearance.bestMatch(
                    from: [.aqua, .darkAqua]) == .darkAqua
                let c = darkMode ? dark : light
                return NSColor(
                    calibratedRed: c.0, green: c.1, blue: c.2, alpha: c.3)
            })
    }

    // MARK: - Surfaces

    /// Main window/content background.
    public static let window = dynamic(
        light: (1.00, 1.00, 1.00, 1), dark: (0.11, 0.11, 0.12, 1))
    /// Sidebar background (pairs with .sidebar material).
    public static let sidebar = dynamic(
        light: (0.96, 0.96, 0.97, 1), dark: (0.13, 0.13, 0.15, 1))
    /// Raised card / grouped-box fill.
    public static let card = dynamic(
        light: (1.00, 1.00, 1.00, 1), dark: (0.17, 0.17, 0.19, 1))
    /// Sunken well (text fields, code blocks).
    public static let well = dynamic(
        light: (0.94, 0.94, 0.96, 1), dark: (0.09, 0.09, 0.10, 1))

    // MARK: - The one divider language

    /// THE divider color app-wide. 1px, no exceptions.
    public static let divider = dynamic(
        light: (0.00, 0.00, 0.00, 0.12), dark: (1.00, 1.00, 1.00, 0.14))

    // MARK: - Text

    public static let textPrimary = dynamic(
        light: (0.00, 0.00, 0.00, 0.85), dark: (1.00, 1.00, 1.00, 0.92))
    public static let textSecondary = dynamic(
        light: (0.00, 0.00, 0.00, 0.55), dark: (1.00, 1.00, 1.00, 0.60))
    /// Supplementary/icon ink only (glyphs, dismiss icons,
    /// separators) — pinned to the WCAG non-text floor 3:1 on every
    /// surface, both appearances (DietContrastTests). Real text uses
    /// secondary/primary.
    public static let textTertiary = dynamic(
        light: (0.00, 0.00, 0.00, 0.46), dark: (1.00, 1.00, 1.00, 0.52))

    // MARK: - Accent + messaging

    public static let accent = NSColor.controlAccentColor
    /// Outgoing bubble fill (accent-tinted).
    public static let bubbleOut = dynamic(
        light: (0.85, 0.90, 1.00, 1), dark: (0.16, 0.28, 0.52, 1))
    /// Incoming bubble fill.
    public static let bubbleIn = dynamic(
        light: (0.92, 0.92, 0.94, 1), dark: (0.22, 0.22, 0.24, 1))

    // MARK: - Presence

    public static let presenceAvailable = NSColor.systemGreen
    public static let presenceBusy = NSColor.systemRed
    public static let presenceAway = NSColor.systemYellow
    public static let presenceOffline = NSColor.systemGray
    public static let presenceDND = NSColor.systemPurple

    // MARK: - Status

    public static let success = NSColor.systemGreen
    public static let warning = NSColor.systemOrange
    public static let danger = NSColor.systemRed
    public static let info = NSColor.systemBlue

    // MARK: - SwiftUI bridges

    public static let windowColor = Color(nsColor: window)
    public static let sidebarColor = Color(nsColor: sidebar)
    public static let cardColor = Color(nsColor: card)
    public static let wellColor = Color(nsColor: well)
    public static let dividerColor = Color(nsColor: divider)
    public static let textPrimaryColor = Color(nsColor: textPrimary)
    public static let textSecondaryColor = Color(nsColor: textSecondary)
    public static let textTertiaryColor = Color(nsColor: textTertiary)
    public static let bubbleOutColor = Color(nsColor: bubbleOut)
    public static let bubbleInColor = Color(nsColor: bubbleIn)

    /// Resolve any token to RGBA under the given appearance (tests).
    public static func resolved(
        _ color: NSColor, dark: Bool
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let app = NSAppearance(
            named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var resolved = color
        app.performAsCurrentDrawingAppearance {
            // cgColor forces dynamic-provider resolution.
            if let flat = NSColor(cgColor: color.cgColor) {
                resolved = flat
            }
        }
        let srgb = resolved.usingColorSpace(.sRGB) ?? resolved
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}
