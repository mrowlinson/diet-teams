// QuickComposerView.swift — f1-composer lane: floating quick-composer
// content (target picker + message field + Send). Target rows reuse
// ForwardPicker (sendable-only: chats + channels, no channel-less team
// rows) + FuzzyMatch ranking — same row data as the Cmd+K palette.
// Esc mirrors QuickComposerModel (message → query → dismiss); Send is
// Cmd+Return (ConversationView sendBox precedent). Zero-refresh: reads
// the list stores' published rows only, never triggers a fetch.
import DietDesign
import OstMacCore
import SwiftUI

/// Floating quick message: pick a sendable target, type, Cmd+Return.
/// `onSend` fires with the picked target id + name + trimmed text; the
/// host posts (`AppState.quickSend`) and dismisses. `signedIn` false
/// disables Send with a "Sign in" hint (never a silent no-op).
public struct QuickComposerView: View {
    private enum Field {
        case target
        case message
    }

    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var teams: TeamsViewModel
    private let signedIn: Bool
    private let initialPickFirst: Bool
    private let onSend: (String, String, String) -> Void
    private let onDismiss: () -> Void
    @State private var targetQuery: String
    @State private var highlight = 0
    @State private var picked: JumpTarget?
    @State private var message: String
    /// Shot-hook auto-pick fired (once: the list loads async after
    /// appear, so appear alone can't trigger it).
    @State private var didAutoPick = false
    @FocusState private var focus: Field?

    public init(
        chats: ChatListViewModel, teams: TeamsViewModel,
        signedIn: Bool,
        initialTargetQuery: String = "",
        initialMessage: String = "",
        initialPickFirst: Bool = false,
        onSend: @escaping (String, String, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.chats = chats
        self.teams = teams
        self.signedIn = signedIn
        self.initialPickFirst = initialPickFirst
        self.onSend = onSend
        self.onDismiss = onDismiss
        _targetQuery = State(initialValue: initialTargetQuery)
        _message = State(initialValue: initialMessage)
    }

    private var sendable: [JumpTarget] {
        ForwardPicker.targets(chats: chats.chats, teams: teams.teams)
    }

    private var matches: [JumpTarget] {
        FuzzyMatch.ranked(sendable, query: targetQuery)
    }

    private var canSend: Bool {
        picked?.openID != nil
            && QuickComposerModel.canSend(text: message, signedIn: signedIn)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let picked {
                pickedRow(picked)
            } else {
                targetField
                DietDividerH()
                targetList
            }
            DietDividerH()
            messageRow
            DietDividerH()
            footer
        }
        .frame(minWidth: 440, idealWidth: 460, maxWidth: 460)
        .background(DietColor.windowColor)
        .onAppear {
            if !autoPickIfNeeded() {
                // Deferred: at summon the panel keys a beat after the
                // content appears, which eats a synchronous focus grab
                // (JumpPaletteView precedent).
                DispatchQueue.main.async { focus = picked == nil ? .target : .message }
            }
        }
        .onChange(of: matches.count) {
            autoPickIfNeeded()
        }
        .onKeyPress(.upArrow) {
            guard focus == .target, picked == nil else { return .ignored }
            highlight = PaletteNav.move(current: highlight, delta: -1, total: matches.count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard focus == .target, picked == nil else { return .ignored }
            highlight = PaletteNav.move(current: highlight, delta: 1, total: matches.count)
            return .handled
        }
        .onKeyPress(.escape) {
            // QuickComposerModel order: message → query → dismiss.
            if !message.isEmpty {
                message = ""
                return .handled
            }
            if !targetQuery.isEmpty {
                targetQuery = ""
                return .handled
            }
            onDismiss()
            return .handled
        }
    }

    // MARK: - Target

    private var targetField: some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(DietColor.textTertiaryColor)
            TextField("To: chat or channel", text: $targetQuery)
                .textFieldStyle(.roundedBorder)
                .font(DietType.title3)
                .foregroundStyle(DietColor.textPrimaryColor)
                .focused($focus, equals: .target)
                .accessibilityLabel("Message target")
                .onSubmit { pick(highlight) }
                .onChange(of: targetQuery) {
                    // All rows are sendable (ForwardPicker), so the
                    // highlight always settles on the top match.
                    highlight = 0
                }
        }
        .padding(DietSpace.md)
    }

    private var targetList: some View {
        Group {
            if matches.isEmpty {
                DietEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: targetQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No chats or channels to message."
                        : "Nothing matches \"\(targetQuery)\". Try fewer letters.")
                    .frame(minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    List(0 ..< matches.count, id: \.self) { i in
                        let t = matches[i]
                        Button { pick(i) } label: {
                            HStack(spacing: DietSpace.sm) {
                                Image(systemName: icon(for: t.kind))
                                    .font(.system(size: DietSize.iconMD))
                                    .foregroundStyle(DietColor.textSecondaryColor)
                                    .frame(width: DietSize.iconLG)
                                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                                    Text(t.title)
                                        .font(DietType.body)
                                        .foregroundStyle(DietColor.textPrimaryColor)
                                        .lineLimit(1)
                                    Text(t.subtitle)
                                        .font(DietType.caption1)
                                        .foregroundStyle(DietColor.textSecondaryColor)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: DietSpace.sm)
                            }
                            .padding(.vertical, DietSpace.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                        .listRowBackground(
                            i == highlight
                                ? Color(nsColor: DietColor.accent).opacity(0.15)
                                : Color.clear)
                    }
                    .listStyle(.plain)
                    .frame(height: JumpPaletteView.listHeight(for: matches.count))
                    .onChange(of: highlight) { proxy.scrollTo(highlight, anchor: .center) }
                }
            }
        }
    }

    private func pickedRow(_ target: JumpTarget) -> some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: icon(for: target.kind))
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(DietColor.textSecondaryColor)
            Text("To:")
                .font(DietType.body)
                .foregroundStyle(DietColor.textSecondaryColor)
            Text(target.openName)
                .font(DietType.body)
                .foregroundStyle(DietColor.textPrimaryColor)
                .lineLimit(1)
            Spacer(minLength: DietSpace.sm)
            Button {
                picked = nil
                focus = .target
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            .buttonStyle(.plain)
            .help("Choose a different target")
            .accessibilityLabel("Clear target")
        }
        .padding(DietSpace.md)
    }

    // MARK: - Message + footer

    private var messageRow: some View {
        HStack(spacing: DietSpace.sm) {
            TextField("Message", text: $message)
                .textFieldStyle(.roundedBorder)
                .plainPasteFallback(into: $message)
                .font(DietType.body)
                .foregroundStyle(DietColor.textPrimaryColor)
                .focused($focus, equals: .message)
                .accessibilityLabel("Message text")
                .onSubmit { send() }
            Button("Send") { send() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(signedIn ? "Send (⌘⏎)" : "Sign in to send")
        }
        .padding(DietSpace.md)
    }

    private var footer: some View {
        HStack(spacing: DietSpace.sm) {
            if !signedIn {
                Text("Sign in to send")
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.warning))
            } else {
                Text(picked == nil ? "↑↓ move · ⏎ select · esc close" : "⏎ send · esc clear/close")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            Spacer(minLength: DietSpace.sm)
        }
        .padding(.horizontal, DietSpace.md)
        .padding(.vertical, DietSpace.sm)
    }

    // MARK: - Actions

    /// Shot-hook pre-pick (once): top match + message focus. Returns
    /// whether it picked (the list may still be loading at appear —
    /// the matches-count change retries when rows land).
    @discardableResult
    private func autoPickIfNeeded() -> Bool {
        guard initialPickFirst, !didAutoPick, picked == nil, !matches.isEmpty else {
            return picked != nil
        }
        didAutoPick = true
        picked = matches[0]
        focus = .message
        return true
    }

    private func pick(_ i: Int) {
        guard matches.indices.contains(i) else { return }
        picked = matches[i]
        focus = .message
    }

    private func send() {
        guard let id = picked?.openID, let target = picked else { return }
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickComposerModel.canSend(text: body, signedIn: signedIn) else { return }
        onSend(id, target.openName, body)
    }

    private func icon(for kind: JumpTarget.Kind) -> String {
        switch kind {
        case .chat: "bubble.left.and.bubble.right"
        case .oneToOne: "person"
        case .channel: "number"
        case .team: "person.3.fill"
        }
    }
}
