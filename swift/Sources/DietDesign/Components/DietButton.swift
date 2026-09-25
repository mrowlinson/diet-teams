// DietButton.swift — icon button. NATIVE UI ONLY: no custom-drawn
// button styles; call sites use system styles (.bordered,
// .borderedProminent, .borderless, .link, .plain) directly.
import SwiftUI

/// Icon-only button with tooltip. System borderless style: native
/// hover + keyboard focus ring. Always pass `label` for VoiceOver.
public struct DietIconButton: View {
    private let systemImage: String
    private let label: String
    private let action: () -> Void

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
            .buttonStyle(.borderless)
            .font(.system(size: DietSize.iconMD))
            .foregroundStyle(DietColor.textSecondaryColor)
            .frame(
                width: DietSize.controlHeight,
                height: DietSize.controlHeight)
            .help(label)
            .focusable()
    }
}
