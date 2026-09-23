// JumpPaletteView.swift — om-cmdk lane: Cmd+K fuzzy jump-to sheet.
// Search field + ranked rows; Up/Down moves, Return jumps, Esc closes.
import DietDesign
import SwiftUI

/// Fuzzy jump-to palette. `targets` is the full row set (chats, channels,
/// teams); filtering + ranking is live via ``FuzzyMatch``. `onPick` fires
/// with the chosen target's open id + name; the host dismisses + opens.
/// `verb` retitles the Return hint when the palette is re-targeted
/// (om-msgactions forwards through this same view).
public struct JumpPaletteView: View {
    private let targets: [JumpTarget]
    private let onPick: (String, String) -> Void
    private let verb: String
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    public init(
        targets: [JumpTarget], initialQuery: String = "", verb: String = "jump",
        onPick: @escaping (String, String) -> Void
    ) {
        self.targets = targets
        _query = State(initialValue: initialQuery)
        self.verb = verb
        self.onPick = onPick
    }

    private var matches: [JumpTarget] {
        FuzzyMatch.ranked(targets, query: query)
    }

    /// Results height: one sidebar row per match + breathing room,
    /// clamped so the sheet never collapses or overflows.
    static func listHeight(for matchCount: Int) -> CGFloat {
        min(320, max(120, CGFloat(matchCount) * DietSize.sidebarRow + DietSpace.sm))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(DietColor.textTertiaryColor)
                TextField("Jump to chat, channel, or team", text: $query)
                    .textFieldStyle(.plain)
                    .font(DietType.title3)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .focused($fieldFocused)
                    .onSubmit { pick(highlight) }
                    .onChange(of: query) { highlight = 0 }
                    // Deferred: at launch the sheet appears before the
                    // window is key, which eats a synchronous focus grab.
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            }
            .padding(DietSpace.md)
            DietDividerH()
            if matches.isEmpty {
                DietEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: emptyMessage)
                    .frame(minHeight: 160)
            } else {
                List(0 ..< matches.count, id: \.self) { i in
                    let t = matches[i]
                    Button {
                        pick(i)
                    } label: {
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
                    .disabled(t.openID == nil)
                    .listRowBackground(
                        i == highlight
                            ? Color(nsColor: DietColor.accent).opacity(0.15)
                            : Color.clear)
                }
                .listStyle(.plain)
                // Explicit height: a bare min/max leaves List at its
                // small ideal size (~3 rows); grow with the matches.
                .frame(height: Self.listHeight(for: matches.count))
            }
            DietDividerH()
            Text("↑↓ move · ⏎ \(verb) · esc close")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .padding(DietSpace.sm)
        }
        .frame(width: 460)
        .background(DietColor.windowColor)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) {
            // Esc with text clears first (spotlight behavior); the host
            // sheet still closes via its own Esc when the query is empty.
            if !query.isEmpty { query = ""; return .handled }
            return .ignored
        }
    }

    private var emptyMessage: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No chats, channels, or teams to jump to."
            : "Nothing matches \"\(query)\". Try fewer letters."
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        highlight = min(max(highlight + delta, 0), matches.count - 1)
    }

    private func pick(_ i: Int) {
        guard matches.indices.contains(i), let id = matches[i].openID else { return }
        onPick(id, matches[i].openName)
    }

    private func icon(for kind: JumpTarget.Kind) -> String {
        switch kind {
        case .chat: "bubble.left.and.bubble.right"
        case .channel: "number"
        case .team: "person.3.fill"
        }
    }
}
