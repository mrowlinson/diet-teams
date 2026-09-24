// DietSpace.swift — 8pt spacing grid + radius + sizing tokens.
// Single source of truth: no raw padding/frame numbers in UI code.
import SwiftUI

/// 8pt grid. Every spacing value is a multiple of 8 (xxs/xs are
/// sub-steps for glyph-level nudges: 2 and 4).
public enum DietSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48

    /// Standard inter-row gap in lists and stacks.
    public static let row: CGFloat = 8
    /// Standard section gap (cards, groups).
    public static let section: CGFloat = 16
    /// Standard window/content edge inset.
    public static let edge: CGFloat = 16
    /// Compact edge inset (sidebar rows, toolbars).
    public static let edgeCompact: CGFloat = 8
}

/// Corner radius tokens. Control = buttons/fields, card = section
/// cards/sheets, bubble = message bubbles, avatar rounds itself.
public enum DietRadius {
    public static let control: CGFloat = 8
    public static let card: CGFloat = 12
    public static let bubble: CGFloat = 16
    public static let pill: CGFloat = 999
}

/// Icon + control sizing tokens (SF Symbols point sizes).
public enum DietSize {
    public static let iconSM: CGFloat = 12
    public static let iconMD: CGFloat = 16
    public static let iconLG: CGFloat = 20
    public static let iconXL: CGFloat = 28
    /// Reaction-picker emoji glyph (fills the 34pt cell).
    public static let emojiMD: CGFloat = 22
    /// Empty-state glyph (DietEmptyState + popover empty states).
    public static let stateIcon: CGFloat = 44
    public static let avatarSM: CGFloat = 24
    public static let avatarMD: CGFloat = 32
    public static let avatarLG: CGFloat = 48
    public static let presenceDot: CGFloat = 10
    /// Minimum tappable control height (HIG: 28pt+ for push buttons).
    public static let controlHeight: CGFloat = 28
    /// Sidebar row height.
    public static let sidebarRow: CGFloat = 56
    /// Toolbar height target (7u on the 8pt grid).
    public static let toolbar: CGFloat = 56
}
