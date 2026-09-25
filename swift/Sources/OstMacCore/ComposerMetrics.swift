// ComposerMetrics.swift — composer layout metrics: 2-line input
// min-height + uniform tool-button cells (GIF matched to icon buttons)
// in a leading 3-over-2 stack beside the field, Send trailing.
// Single source of truth: sendBox + tests read these, no raw numbers.
import SwiftUI

import DietDesign

/// Composer layout numbers (composer-rearrange).
public enum ComposerMetrics {
    /// Resting input height in lines; the field grows past this
    /// (lineLimit inputMinLines...).
    public static let inputMinLines = 2
    /// Resting input min-height in points: two single-line rows.
    /// lineLimit alone does not reserve the second row under the
    /// roundedBorder style, so the frame enforces it.
    public static let inputMinHeight: CGFloat = DietSpace.xxl
    /// Leading-stack top-row control count (attach, @, GIF).
    public static let leadingTopCount = 3
    /// Leading-stack bottom-row control count (schedule, template).
    public static let leadingBottomCount = 2
    /// Uniform tool-button cell width. Fits the "GIF" caption-bold
    /// label; icon buttons center in the same cell.
    public static let toolButtonWidth: CGFloat = 32
    /// Uniform tool-button cell height. Two stacked rows + one xs gap
    /// equal inputMinHeight, so the stack matches the field exactly.
    public static let toolButtonHeight: CGFloat =
        (inputMinHeight - DietSpace.xs) / 2
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
