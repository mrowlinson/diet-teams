// DietField.swift — text fields: search + composer. Focus ring
// via accent outline; keyboard: Escape clears search.
import SwiftUI

/// Search field: magnifier, clear button, Escape-to-clear.
public struct DietSearchField: View {
    private let prompt: String
    @Binding private var text: String
    @FocusState private var focused: Bool

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    public var body: some View {
        HStack(spacing: DietSpace.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(DietColor.textTertiaryColor)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DietType.body)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(DietColor.textTertiaryColor)
            }
        }
        .padding(.horizontal, DietSpace.sm)
        .frame(height: DietSize.controlHeight)
        .background(DietColor.wellColor)
        .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DietRadius.control)
                .stroke(
                    focused ? Color.accentColor
                        : DietColor.dividerColor,
                    lineWidth: focused ? 2 : 1)
        )
    }
}

/// Composer row: multiline field + send button (Return sends).
public struct DietComposer: View {
    private let prompt: String
    @Binding private var text: String
    private let onSend: () -> Void
    @FocusState private var focused: Bool

    public init(
        _ prompt: String, text: Binding<String>,
        onSend: @escaping () -> Void
    ) {
        self.prompt = prompt
        _text = text
        self.onSend = onSend
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: DietSpace.sm) {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DietType.body)
                .focused($focused)
                .padding(.horizontal, DietSpace.sm)
                .frame(minHeight: DietSize.controlHeight)
                .background(DietColor.wellColor)
                .clipShape(
                    RoundedRectangle(cornerRadius: DietRadius.control))
                .overlay(
                    RoundedRectangle(
                        cornerRadius: DietRadius.control
                    ).stroke(
                        focused ? Color.accentColor
                            : DietColor.dividerColor,
                        lineWidth: focused ? 2 : 1)
                )
                .onSubmit { if !text.isEmpty { onSend() } }
            Button(
                "Send", systemImage: "paperplane.fill",
                action: onSend
            )
            .buttonStyle(.dietPrimary)
            .disabled(text.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
