// AppNavRail.swift — Teams-like app navigation rail (R8 app-nav lane).
//
// Replaces the 7-tab DietSegmentedPicker section bar, whose
// NSSegmentedControl intrinsic width (~480pt for 7 segments) exceeded
// the sidebar column (240–300pt): segments truncated at ideal width,
// and at small window sizes the sidebar VStack overflowed its column
// ~30px left of the window edge (narrow-clip defect). The rail is a
// fixed-width VStack of native Buttons — zero intrinsic-width
// pressure — so the column holds its width at every window size.
//
// Rows iterate SidebarSection.allCases: future E/F surfaces appear in
// the rail with no change here.
import DietDesign
import SwiftUI

/// Rail geometry + sidebar fit math. Single source of truth for the
/// column minimum (RootView's `navigationSplitViewColumnWidth` reads
/// `sidebarMinWidth`, so the fit test below guards the live layout).
public enum AppNavLayout {
    /// Fixed rail width (icon + caption2 label, longest: "Transcripts").
    public static let railWidth: CGFloat = 72
    /// One section row (icon + label + compact padding).
    public static let rowHeight: CGFloat = 48
    /// Sidebar column minimum (== RootView column min).
    public static let sidebarMinWidth: CGFloat = 240
    /// Narrowest usable browser list beside the rail (search + rows).
    public static let minBrowserWidth: CGFloat = 160
    /// Window minimum height (== RootView frame min).
    public static let minWindowHeight: CGFloat = 520
    /// Non-rail chrome inside the min height (status bar + seams).
    public static let chromeHeight: CGFloat = 32

    /// Rail rows, in section order (data-driven — future cases incl).
    public static func rows() -> [SidebarSection] {
        Array(SidebarSection.allCases)
    }

    /// Stacked rail height for `sectionCount` rows (no scroll iff this
    /// fits the window height minus chrome).
    public static func stackHeight(sectionCount: Int) -> CGFloat {
        CGFloat(sectionCount) * rowHeight
    }
}

public extension SidebarSection {
    /// SF Symbol per section (all present on the macOS 14 target).
    var systemImage: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .teams: "person.3"
        case .contacts: "person.crop.circle"
        case .reminders: "checklist"
        case .planner: "square.grid.2x2"
        case .recordings: "record.circle"
        case .transcripts: "doc.text"
        case .shifts: "calendar.badge.clock"
        }
    }
}

/// Teams-style app rail: icon + label per section, selected row in
/// accent. Native Buttons only (diet tokens type/color only).
public struct AppNavRail: View {
    @Binding private var selection: SidebarSection

    public init(selection: Binding<SidebarSection>) {
        _selection = selection
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(AppNavLayout.rows(), id: \.self) { section in
                let selected = section == selection
                Button {
                    selection = section
                } label: {
                    VStack(spacing: DietSpace.xxs) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: DietSize.iconLG))
                            .foregroundStyle(
                                selected ? Color.accentColor
                                    : DietColor.textSecondaryColor)
                        Text(section.rawValue)
                            .font(DietType.caption2)
                            .foregroundStyle(
                                selected ? DietColor.textPrimaryColor
                                    : DietColor.textSecondaryColor)
                            .lineLimit(1)
                    }
                    .frame(
                        maxWidth: .infinity, minHeight: AppNavLayout.rowHeight,
                        maxHeight: AppNavLayout.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    selected ? Color.accentColor.opacity(0.12) : .clear)
                .accessibilityIdentifier(
                    "appnav-\(section.rawValue.lowercased())")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help(section.rawValue)
            }
            Spacer(minLength: 0)
        }
        .frame(width: AppNavLayout.railWidth)
    }
}
