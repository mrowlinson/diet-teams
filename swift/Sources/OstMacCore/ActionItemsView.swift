// ActionItemsView.swift — f1-actions lane: extraction popover +
// shared bullets list.
//
// The popover mirrors the CatchUp popover (popover, not a window-modal
// sheet, so click-outside dismisses; every close resets the state).
// The bullets list is shared by the conversation popover and the
// transcripts turns card.
import AppKit
import DietDesign
import SwiftUI

/// Popover open/dismiss router (mirrors CatchUpSheet): every path
/// closes AND resets the extraction state.
@MainActor
public enum ActionItemsSheet {
    public static func open(presented: Binding<Bool>, store: ActionItemsStore) {
        store.reset()
        presented.wrappedValue = true
    }

    public static func dismissViaDone(presented: Binding<Bool>, store: ActionItemsStore) {
        close(presented: presented, store: store)
    }

    public static func dismissViaEscape(presented: Binding<Bool>, store: ActionItemsStore) {
        close(presented: presented, store: store)
    }

    public static func dismissViaClickOutside(presented: Binding<Bool>, store: ActionItemsStore) {
        close(presented: presented, store: store)
    }

    private static func close(presented: Binding<Bool>, store: ActionItemsStore) {
        presented.wrappedValue = false
        store.reset()
    }
}

/// Popover content: one Extract tap → reviewable bullets (owner +
/// source timestamp) over the current thread.
public struct ActionItemsView: View {
    @ObservedObject private var actions: ActionItemsStore
    private let messages: [ChatMessage]
    private let chatID: String?
    private let autoRun: Bool
    private let onDone: () -> Void

    /// - chatID: scopes the extraction cache to this thread (nil still
    ///   caches, keyed on message identity).
    /// - autoRun: extract once on appear (the --show-action-items shot
    ///   hook only; real taps always come from the button).
    /// - onDone: Done / Esc tap. The host routes it through
    ///   `ActionItemsSheet.dismissViaDone` (close + state reset).
    public init(
        actions: ActionItemsStore, messages: [ChatMessage], chatID: String? = nil,
        autoRun: Bool = false, onDone: @escaping () -> Void = {}
    ) {
        self.actions = actions
        self.messages = messages
        self.chatID = chatID
        self.autoRun = autoRun
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.section) {
            HStack {
                Text("Action items")
                    .font(DietType.headline)
                Spacer(minLength: DietSpace.section)
                // Native macOS dismiss: a visible Done button that ALSO
                // owns .cancelAction, so Esc dismisses from any focus
                // (no focus trap). Extract keeps .defaultAction (Return);
                // the two shortcuts never conflict.
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            Text(CatchUp.onDevicePrivacyNote)
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
            DietSeamH()
            stateBody
            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 440, height: 380)
        .task {
            if autoRun, actions.state == .idle {
                await actions.extractFromMessages(messages, chatID: chatID)
            }
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch actions.state {
        case .idle:
            Text("Extract action items from \(messages.count) messages, on this Mac.")
                .font(DietType.body)
                .foregroundStyle(DietColor.textSecondaryColor)
            Button("Extract") {
                Task { await actions.extractFromMessages(messages, chatID: chatID) }
            }
            .keyboardShortcut(.defaultAction)
        case .loading:
            HStack {
                Spacer()
                ProgressView("Extracting…")
                Spacer()
            }
            .padding(.top, DietSpace.lg)
        case let .loaded(items):
            ActionItemsBulletsView(items: items)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    ActionItemsBulletsView.plainText(items), forType: .string)
            }
            .buttonStyle(.link)
        case let .empty(copy):
            Text(copy)
                .font(DietType.body)
                .foregroundStyle(DietColor.textSecondaryColor)
        case let .failed(detail):
            Text(detail)
                .font(DietType.body)
                .foregroundStyle(Color(nsColor: DietColor.danger))
                .textSelection(.enabled)
            if actions.lastError?.isOnDevice == true {
                CatchUpOnDeviceGuidance()
            }
            Button("Retry") {
                Task { await actions.extractFromMessages(messages, chatID: chatID) }
            }
            .buttonStyle(.link)
        }
    }
}

/// Reviewable bullets: title + owner + source timestamp label. Shared
/// by the conversation popover and the transcripts turns card.
public struct ActionItemsBulletsView: View {
    private let items: [ActionItem]

    public init(items: [ActionItem]) {
        self.items = items
    }

    /// "• title — owner [m:ss]" per item (Copy button payload).
    public static func plainText(_ items: [ActionItem]) -> String {
        items.map { item in
            var line = "• \(item.title) — \(item.owner)"
            if let label = item.sourceLabel {
                line += " [\(label)]"
            }
            return line
        }.joined(separator: "\n")
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DietSpace.xs) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(DietType.body)
                            .foregroundStyle(DietColor.textPrimaryColor)
                        HStack(spacing: DietSpace.xs) {
                            Text(item.owner)
                                .font(DietType.caption1)
                                .fontWeight(.semibold)
                                .foregroundStyle(DietColor.textPrimaryColor)
                            if let label = item.sourceLabel {
                                Text(label)
                                    .font(DietType.caption1)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
