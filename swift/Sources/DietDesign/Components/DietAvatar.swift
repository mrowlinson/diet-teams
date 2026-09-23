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
                    saturation: 0.45, brightness: 0.72))
                .frame(width: size, height: size)
                .overlay(
                    Text(Self.initials(for: displayName))
                        .font(.system(
                            size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                )
            if let presence {
                DietPresenceDot(presence)
                    .offset(x: DietSpace.xxs, y: DietSpace.xxs)
            }
        }
        .accessibilityLabel("\(displayName), \(presence?.label ?? "no status")")
    }
}
