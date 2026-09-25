// MessageDensity.swift — f2-density lane: message-density options.
//
// One global setting (Comfortable default / Compact) under
// Settings → Chats → Appearance. Density is SPACING ONLY — fonts,
// colors, and token values never change; Comfortable resolves to
// today's exact constants. Compact tightens the timeline (row gap,
// bubble padding, day separators) and the sidebar chat rows (row
// padding, avatar) so more fits on screen.
//
// Plumbing: a pure per-mode metrics map + a SwiftUI EnvironmentKey.
// Views read the value at the padding/spacing call sites only (no
// per-row ObservableObject subscriptions). DietSpace/DietSize stay
// canonical — the map references their constants, never mutates
// them. DietDesign views that need density (day separator) take a
// plain `compact:` init param so DietDesign keeps zero knowledge of
// this module.
import DietDesign
import Foundation
import SwiftUI

/// Message density: Comfortable (today's layout, default) or Compact
/// (tighter spacing, same type).
public enum MessageDensity: String, CaseIterable, Sendable {
    case comfortable
    case compact

    public var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// Spacing map for this mode. Comfortable pins today's constants
    /// exactly (MessageDensityTests asserts each against DietSpace /
    /// DietSize); compact tightens gaps/padding/avatar only.
    public var metrics: MessageDensityMetrics {
        switch self {
        case .comfortable:
            return MessageDensityMetrics(
                rowGap: DietSpace.sm,
                bubblePad: DietSpace.sm + DietSpace.xs,
                separatorPad: DietSpace.xs,
                sidebarRowPad: DietSpace.xs,
                avatarSize: DietSize.avatarMD,
                timelineEdge: DietSpace.md)
        case .compact:
            return MessageDensityMetrics(
                rowGap: DietSpace.xs,
                bubblePad: DietSpace.sm,
                separatorPad: DietSpace.xxs,
                sidebarRowPad: DietSpace.xxs,
                avatarSize: DietSize.avatarSM,
                timelineEdge: DietSpace.md)
        }
    }
}

/// Pure spacing values for one density mode. All values resolve from
/// DietSpace/DietSize constants (tokens stay canonical).
public struct MessageDensityMetrics: Equatable, Sendable {
    /// Timeline LazyVStack row gap (8 → 4).
    public let rowGap: CGFloat
    /// MessageBubble inner padding (12 → 8).
    public let bubblePad: CGFloat
    /// Day-separator vertical padding (4 → 2).
    public let separatorPad: CGFloat
    /// Sidebar chat-row vertical padding (4 → 2).
    public let sidebarRowPad: CGFloat
    /// Sidebar chat-row avatar size (32 → 24).
    public let avatarSize: CGFloat
    /// Timeline edge inset (16 both modes — density tightens rows,
    /// not the content frame).
    public let timelineEdge: CGFloat

    public init(
        rowGap: CGFloat, bubblePad: CGFloat, separatorPad: CGFloat,
        sidebarRowPad: CGFloat, avatarSize: CGFloat,
        timelineEdge: CGFloat
    ) {
        self.rowGap = rowGap
        self.bubblePad = bubblePad
        self.separatorPad = separatorPad
        self.sidebarRowPad = sidebarRowPad
        self.avatarSize = avatarSize
        self.timelineEdge = timelineEdge
    }
}

/// Persisted density store: one raw-string key (QuietHours/GhostStore
/// precedent — suite-injectable UserDefaults, @Published + didSet).
@MainActor
public final class DensityStore: ObservableObject {
    public static let modeKey = "om.messageDensity"

    private let defaults: UserDefaults

    @Published public var mode: MessageDensity {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// Nonisolated so views can take a default `DensityStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    /// Unknown/missing raw values fall back to Comfortable (fresh
    /// installs + forward-compat).
    public nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.modeKey)
        let mode = raw.flatMap(MessageDensity.init(rawValue:)) ?? .comfortable
        _mode = Published(initialValue: mode)
    }
}

private struct MessageDensityKey: EnvironmentKey {
    static let defaultValue: MessageDensity = .comfortable
}

public extension EnvironmentValues {
    var messageDensity: MessageDensity {
        get { self[MessageDensityKey.self] }
        set { self[MessageDensityKey.self] = newValue }
    }
}

/// Host that publishes one DensityStore's mode into the SwiftUI
/// environment. The single @ObservedObject subscription lives here —
/// rows read the plain value downstream (no per-row subscriptions).
/// Mode flips re-layout only: no store invalidation, no re-parse,
/// no scroll calls (scroll position holds by row identity).
public struct DensityHost<Content: View>: View {
    @ObservedObject private var density: DensityStore
    private let content: Content

    public init(
        density: DensityStore,
        @ViewBuilder content: () -> Content
    ) {
        self.density = density
        self.content = content()
    }

    public var body: some View {
        content.environment(\.messageDensity, density.mode)
    }
}
