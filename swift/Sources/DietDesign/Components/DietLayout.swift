// DietLayout.swift — window/sidebar materials + native containers.
// Multi-column surfaces use NavigationSplitView; grouped content
// uses GroupBox; per-column header alignment stays DietHeaderBar.
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

/// Two-column app frame: native NavigationSplitView (sidebar +
/// detail, system material, collapsible sidebar).
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
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Section card: native GroupBox for grouped content.
public struct DietCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        GroupBox {
            content
        }
    }
}

/// Card with a title row: native GroupBox with label.
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
        GroupBox {
            content
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }
}
