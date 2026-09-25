// ComposerMetrics.swift — composer-2line layout metrics: 2-line input
// min-height + uniform tool-button cells (GIF matched to icon buttons).
// Single source of truth: sendBox + tests read these, no raw numbers.
import SwiftUI

import DietDesign

/// Composer layout numbers (composer-2line).
public enum ComposerMetrics {
    /// Resting input height in lines; the field grows past this
    /// (lineLimit inputMinLines...).
    public static let inputMinLines = 2
    /// Resting input min-height in points: two single-line rows.
    /// lineLimit alone does not reserve the second row under the
    /// roundedBorder style, so the frame enforces it.
    public static let inputMinHeight: CGFloat = DietSpace.xxl
    /// Uniform tool-button cell width. Fits the "GIF" caption-bold
    /// label; icon buttons center in the same cell.
    public static let toolButtonWidth: CGFloat = 32
    /// Uniform tool-button cell height (= HIG push-button minimum).
    public static let toolButtonHeight: CGFloat = DietSize.controlHeight
}

/// Uniform bordered-icon chrome for composer tool buttons. Every tool
/// button (attach, @, GIF, clock, templates) renders exactly the
/// ComposerMetrics cell, so the GIF text label matches the icon
/// buttons pixel-for-pixel on frame.
public struct ComposerToolButtonChrome: ViewModifier {
    public var hovering: Bool

    public init(hovering: Bool) {
        self.hovering = hovering
    }

    public func body(content: Content) -> some View {
        content
            .foregroundStyle(DietColor.textSecondaryColor)
            .frame(
                minWidth: ComposerMetrics.toolButtonWidth,
                minHeight: ComposerMetrics.toolButtonHeight
            )
            .background(
                hovering ? DietColor.wellColor : .clear,
                in: RoundedRectangle(cornerRadius: DietRadius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .stroke(DietColor.dividerColor, lineWidth: 1)
            )
    }
}

public extension View {
    /// Apply the uniform composer tool-button cell + hover chrome.
    func composerToolButton(hovering: Bool) -> some View {
        modifier(ComposerToolButtonChrome(hovering: hovering))
    }
}
