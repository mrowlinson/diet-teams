// DietStates.swift — empty states + banners + sheet chrome.
import SwiftUI

/// Empty state: large SF Symbol, title, body, optional action.
/// Real guidance, never a bare "No items".
public struct DietEmptyState: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionLabel: String?
    private let action: (() -> Void)?

    public init(
        systemImage: String, title: String, message: String,
        actionLabel: String? = nil, action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        VStack(spacing: DietSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DietSize.stateIcon))
                .foregroundStyle(DietColor.textTertiaryColor)
                .padding(.bottom, DietSpace.xs)
            Text(title)
                .font(DietType.title3)
                .foregroundStyle(DietColor.textPrimaryColor)
            Text(message)
                .font(DietType.body)
                .foregroundStyle(DietColor.textSecondaryColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.dietSecondary)
                    .padding(.top, DietSpace.sm)
            }
        }
        .padding(DietSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Banner severity → (symbol, tint). No raw strings in callers.
public enum DietBannerStyle {
    case info, success, warning, error

    var systemImage: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .info: return DietColor.info
        case .success: return DietColor.success
        case .warning: return DietColor.warning
        case .error: return DietColor.danger
        }
    }
}

/// Inline banner: tinted wash, symbol, message, dismiss.
public struct DietBanner: View {
    private let style: DietBannerStyle
    private let message: String
    private let onDismiss: (() -> Void)?

    public init(
        _ style: DietBannerStyle, message: String,
        onDismiss: (() -> Void)? = nil
    ) {
        self.style = style
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: style.systemImage)
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(Color(nsColor: style.tint))
            Text(message)
                .font(DietType.callout)
                .foregroundStyle(DietColor.textPrimaryColor)
            Spacer(minLength: DietSpace.sm)
            if let onDismiss {
                DietIconButton("Dismiss", systemImage: "xmark") {
                    onDismiss()
                }
            }
        }
        .padding(DietSpace.sm)
        .background(
            Color(nsColor: style.tint).opacity(0.12),
            in: RoundedRectangle(cornerRadius: DietRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DietRadius.control)
                .stroke(
                    Color(nsColor: style.tint).opacity(0.35),
                    lineWidth: 1)
        )
    }
}

/// Sheet chrome: title bar + seam + padded body. Fixed 8pt rhythm.
public struct DietSheet<Content: View>: View {
    private let title: String
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(DietType.title3)
                    .foregroundStyle(DietColor.textPrimaryColor)
                Spacer(minLength: DietSpace.sm)
            }
            .padding(DietSpace.md)
            DietSeamH()
            content.padding(DietSpace.md)
        }
        .frame(minWidth: 400)
        .background(DietColor.windowColor)
    }
}
