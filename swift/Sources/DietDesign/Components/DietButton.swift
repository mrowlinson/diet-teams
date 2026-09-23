// DietButton.swift — button styles. Hover + focus + keyboard states.
import SwiftUI

/// Primary action (accent fill, white text).
public struct DietPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DietType.body)
            .padding(.horizontal, DietSpace.md)
            .frame(minHeight: DietSize.controlHeight)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(
                RoundedRectangle(cornerRadius: DietRadius.control))
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// Secondary action (well fill, accent text on hover).
public struct DietSecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DietType.body)
            .padding(.horizontal, DietSpace.md)
            .frame(minHeight: DietSize.controlHeight)
            .background(DietColor.wellColor)
            .foregroundStyle(
                hovering ? Color.accentColor
                    : DietColor.textPrimaryColor)
            .clipShape(
                RoundedRectangle(cornerRadius: DietRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .stroke(DietColor.dividerColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { hovering = $0 }
    }
}

/// Destructive action (red text, red wash on hover).
public struct DietDestructiveButtonStyle: ButtonStyle {
    @State private var hovering = false
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DietType.body)
            .padding(.horizontal, DietSpace.md)
            .frame(minHeight: DietSize.controlHeight)
            .background(
                hovering ? Color(nsColor: DietColor.danger)
                    .opacity(0.12) : .clear)
            .foregroundStyle(Color(nsColor: DietColor.danger))
            .clipShape(
                RoundedRectangle(cornerRadius: DietRadius.control))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { hovering = $0 }
    }
}

/// Icon-only toolbar button with hover wash + tooltip.
/// Always pass `label` for VoiceOver.
public struct DietIconButton: View {
    private let systemImage: String
    private let label: String
    private let action: () -> Void
    @State private var hovering = false

    public init(
        _ label: String, systemImage: String,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(label, systemImage: systemImage, action: action)
            .buttonStyle(.plain)
            .font(.system(size: DietSize.iconMD))
            .foregroundStyle(DietColor.textSecondaryColor)
            .frame(
                width: DietSize.controlHeight,
                height: DietSize.controlHeight)
            .background(
                hovering ? DietColor.wellColor : .clear,
                in: RoundedRectangle(
                    cornerRadius: DietRadius.control))
            .onHover { hovering = $0 }
            .help(label)
            .focusable()
    }
}

public extension ButtonStyle where Self == DietPrimaryButtonStyle {
    static var dietPrimary: DietPrimaryButtonStyle { .init() }
}

public extension ButtonStyle where Self == DietSecondaryButtonStyle {
    static var dietSecondary: DietSecondaryButtonStyle { .init() }
}

public extension ButtonStyle where Self == DietDestructiveButtonStyle {
    static var dietDestructive: DietDestructiveButtonStyle { .init() }
}
