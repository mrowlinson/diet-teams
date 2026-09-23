// DietLayout.swift — window/sidebar materials + seam alignment.
// Every multi-column surface uses DietColumns so toolbar, sidebar,
// and content seams share one divider row and pixel-align.
import AppKit
import SwiftUI

/// True sidebar vibrancy: NSVisualEffectView .sidebar material.
/// Falls back gracefully (layer shows DietColor.sidebar under it).
public struct DietSidebarMaterial: NSViewRepresentable {
    public init() {}

    public func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

/// Two-column app frame: sidebar + content with a shared toolbar
/// seam. Sidebar gets .sidebar material; content gets window bg.
/// The vertical seam and the horizontal toolbar seam are both
/// DietDivider (1px), drawn in the same coordinate pass so they
/// meet exactly — no double lines, no gaps.
public struct DietColumns<Sidebar: View, Content: View>: View {
    private let sidebar: Sidebar
    private let content: Content
    private let title: String

    public init(
        title: String, @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.sidebar = sidebar()
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                .background(DietSidebarMaterial())
            DietDividerV()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DietColor.windowColor)
        }
        .navigationTitle(title)
    }
}

/// Toolbar-height header row that aligns with the window toolbar:
/// fixed height + bottom seam. Use inside content columns so the
/// content header seam sits on the same row as the sidebar's.
public struct DietHeaderBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(height: DietSize.toolbar)
                .padding(.horizontal, DietSpace.edge)
            DietSeamH()
        }
    }
}

/// Section card: grouped content on window bg. 12pt radius,
/// 1px border in divider color, 16pt padding.
public struct DietCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(DietSpace.md)
            .background(DietColor.cardColor)
            .clipShape(RoundedRectangle(cornerRadius: DietRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.card)
                    .stroke(DietColor.dividerColor, lineWidth: 1)
            )
    }
}

/// Card with a title row: caption header + divider + body.
public struct DietSectionCard<Content: View>: View {
    private let title: String
    private let systemImage: String?
    private let content: Content

    public init(
        _ title: String, systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DietSpace.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: DietSize.iconSM))
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                Text(title.uppercased())
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            .padding(.horizontal, DietSpace.md)
            .padding(.top, DietSpace.sm + DietSpace.xs)
            .padding(.bottom, DietSpace.sm)
            DietDividerH()
            content.padding(DietSpace.md)
        }
        .background(DietColor.cardColor)
        .clipShape(RoundedRectangle(cornerRadius: DietRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DietRadius.card)
                .stroke(DietColor.dividerColor, lineWidth: 1)
        )
    }
}
