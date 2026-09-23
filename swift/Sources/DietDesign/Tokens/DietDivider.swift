// DietDivider.swift — the single divider language app-wide.
// 1px DietColor.divider, zero insets by default (caller insets).
// Fixes om-shared-tab defect: toolbar/sidebar/content seams share
// one weight + color and align on the same pixel rows.
import SwiftUI

/// Horizontal 1px divider. Spans full width; inset via padding.
public struct DietDividerH: View {
    public init() {}
    public var body: some View {
        DietColor.dividerColor.frame(height: 1)
    }
}

/// Vertical 1px divider for column seams.
public struct DietDividerV: View {
    public init() {}
    public var body: some View {
        DietColor.dividerColor.frame(width: 1)
    }
}

/// Seam: the toolbar/content and sidebar/content boundary.
/// Same 1px divider, pinned so adjacent columns share the row.
public struct DietSeamH: View {
    public init() {}
    public var body: some View {
        DietDividerH()
    }
}
