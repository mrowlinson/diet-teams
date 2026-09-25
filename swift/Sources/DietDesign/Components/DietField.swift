// DietField.swift — text fields: search + composer. NATIVE UI ONLY:
// system rounded-bezel fields; the system focus ring carries focus.
// Diet tokens for type/color only. Keyboard: Escape clears search,
// Return sends the composer.
import SwiftUI

/// Search field: magnifier, clear button, Escape-to-clear.
public struct DietSearchField: View {
    private let prompt: String
    @Binding private var text: String

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
                .textFieldStyle(.roundedBorder)
                .font(DietType.body)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(DietColor.textTertiaryColor)
            }
        }
    }
}

/// Composer row: field + send button (Return sends).
public struct DietComposer: View {
    private let prompt: String
    @Binding private var text: String
    private let onSend: () -> Void

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
                .textFieldStyle(.roundedBorder)
                .font(DietType.body)
                .onSubmit { if !text.isEmpty { onSend() } }
            Button(
                "Send", systemImage: "paperplane.fill",
                action: onSend
            )
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
