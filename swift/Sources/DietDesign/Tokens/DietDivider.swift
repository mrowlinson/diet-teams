// DietDivider.swift — the single divider language app-wide.
// Native SwiftUI Divider (auto-orients: horizontal in VStack,
// vertical in HStack). Zero insets by default (caller insets).
// Fixes om-shared-tab defect: toolbar/sidebar/content seams share
// one system weight + color and align on the same pixel rows.
import SwiftUI

/// Horizontal divider. Spans full width; inset via padding.
public struct DietDividerH: View {
    public init() {}
    public var body: some View {
        Divider()
    }
}

/// Vertical divider for column seams.
public struct DietDividerV: View {
    public init() {}
    public var body: some View {
        Divider()
    }
}

/// Seam: the toolbar/content and sidebar/content boundary.
/// Same system divider, pinned so adjacent columns share the row.
public struct DietSeamH: View {
    public init() {}
    public var body: some View {
        Divider()
    }
}
