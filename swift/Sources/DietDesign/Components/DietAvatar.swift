// DietAvatar.swift — avatars + presence dots. Initials, SF Symbol
// fallback; zero raw ids (display name required).
import SwiftUI

/// Presence states with system colors (no raw values in UI).
public enum DietPresence: String, CaseIterable {
    case available, busy, away, offline, dnd

    public var color: NSColor {
        switch self {
        case .available: return DietColor.presenceAvailable
        case .busy: return DietColor.presenceBusy
        case .away: return DietColor.presenceAway
        case .offline: return DietColor.presenceOffline
        case .dnd: return DietColor.presenceDND
        }
    }

    public var label: String {
        switch self {
        case .available: return "Available"
        case .busy: return "Busy"
        case .away: return "Away"
        case .offline: return "Offline"
        case .dnd: return "Do not disturb"
        }
    }

    public var systemImage: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .busy: return "xmark.circle.fill"
        case .away: return "clock.fill"
        case .offline: return "circle"
        case .dnd: return "moon.fill"
        }
    }
}

/// Presence dot: 10pt circle with 2pt window-color ring.
public struct DietPresenceDot: View {
    private let presence: DietPresence

    public init(_ presence: DietPresence) {
        self.presence = presence
    }

    public var body: some View {
        Circle()
            .fill(Color(nsColor: presence.color))
            .frame(
                width: DietSize.presenceDot,
                height: DietSize.presenceDot)
            .overlay(
                Circle().stroke(
                    DietColor.windowColor, lineWidth: 2))
            .accessibilityLabel(presence.label)
    }
}

/// Avatar: initials on deterministic hue, optional presence dot.
/// Hue derives from the name hash (stable, no stored ids).
public struct DietAvatar: View {
    private let displayName: String
    private let presence: DietPresence?
    private let size: CGFloat

    public init(
        _ displayName: String,
        presence: DietPresence? = nil,
        size: CGFloat = DietSize.avatarMD
    ) {
        self.displayName = displayName
        self.presence = presence
        self.size = size
    }

    /// Stable hue 0–1 from name (tests pin determinism).
    public static func hue(for name: String) -> Double {
        var hash = 5381
        for scalar in name.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return Double(abs(hash) % 360) / 360.0
    }

    /// Avatar fill saturation/brightness (hue derives from the name).
    public static let fillSaturation = 0.45
    public static let fillBrightness = 0.72

    /// sRGB fill for a hue (mirrors the body's Color(hue:...)).
    public static func fillRGB(forHue hue: Double) -> (
        r: CGFloat, g: CGFloat, b: CGFloat
    ) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1) * 6
        let s = CGFloat(fillSaturation)
        let v = CGFloat(fillBrightness)
        let c = v * s
        let x = c * (1 - abs((h.truncatingRemainder(dividingBy: 2)) - 1))
        let m = v - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    /// Dark initials on light fills so initials hold 4.5:1
    /// everywhere. Flips when the white ratio drops below 4.6 — past
    /// that crossover black always clears 4.5 with margin.
    public static func useDarkInitials(forHue hue: Double) -> Bool {
        let f = fillRGB(forHue: hue)
        let lum = 0.2126 * linear(f.r) + 0.7152 * linear(f.g)
            + 0.0722 * linear(f.b)
        return (1.05 / (lum + 0.05)) < 4.6
    }

    private static func linear(_ c: CGFloat) -> CGFloat {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// 1–2 uppercase initials (tests pin edge cases).
    public static func initials(for name: String) -> String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        switch parts.count {
        case 0: return "?"
        case 1: return String(parts[0].prefix(2)).uppercased()
        default:
            return String(parts[0].prefix(1) + parts[1].prefix(1))
                .uppercased()
        }
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color(
                    hue: Self.hue(for: displayName),
                    saturation: Self.fillSaturation,
                    brightness: Self.fillBrightness))
                .frame(width: size, height: size)
                .overlay(
                    Text(Self.initials(for: displayName))
                        .font(.system(
                            size: size * 0.38, weight: .semibold))
                        .foregroundStyle(
                            Self.useDarkInitials(
                                forHue: Self.hue(for: displayName))
                                ? .black : .white)
                )
            if let presence {
                DietPresenceDot(presence)
                    .offset(x: DietSpace.xxs, y: DietSpace.xxs)
            }
        }
        .accessibilityLabel("\(displayName), \(presence?.label ?? "no status")")
    }
}
