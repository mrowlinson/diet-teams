// JumpPaletteView.swift — om-cmdk lane: Cmd+K fuzzy jump-to sheet.
// Search field + ranked rows; Up/Down moves, Return jumps, Esc closes.
import SwiftUI

/// Fuzzy jump-to palette. `targets` is the full row set (chats, channels,
/// teams); filtering + ranking is live via ``FuzzyMatch``. `onPick` fires
/// with the chosen target's open id + name; the host dismisses + opens.
public struct JumpPaletteView: View {
    private let targets: [JumpTarget]
    private let onPick: (String, String) -> Void
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    public init(targets: [JumpTarget], initialQuery: String = "", onPick: @escaping (String, String) -> Void) {
        self.targets = targets
        _query = State(initialValue: initialQuery)
        self.onPick = onPick
    }

    private var matches: [JumpTarget] {
        FuzzyMatch.ranked(targets, query: query)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to chat, channel, or team", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { pick(highlight) }
                    .onChange(of: query) { highlight = 0 }
                    // Deferred: at launch the sheet appears before the
                    // window is key, which eats a synchronous focus grab.
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            }
            .padding(12)
            Divider()
            if matches.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(0 ..< matches.count, id: \.self) { i in
                    let t = matches[i]
                    Button {
                        pick(i)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: t.kind))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).lineLimit(1)
                                Text(t.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(t.openID == nil)
                    .listRowBackground(i == highlight ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .listStyle(.plain)
                // Explicit height: a bare min/max leaves List at its
                // small ideal size (~3 rows); grow with the matches.
                .frame(height: min(320, max(120, CGFloat(matches.count) * 56 + 8)))
            }
            Divider()
            Text("↑↓ move · ⏎ jump · esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 460)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) {
            // Esc with text clears first (spotlight behavior); the host
            // sheet still closes via its own Esc when the query is empty.
            if !query.isEmpty { query = ""; return .handled }
            return .ignored
        }
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
