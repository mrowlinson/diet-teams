// ReactionPickerView.swift — om-react-polish: the more-picker grid
// (search + recents + categories) shown in a transient popover from the
// menu row's ＋ button. Native controls only: text field, segmented
// categories, plain buttons in a lazy grid.
// om-react-picker: Esc dismisses (via `onDismiss`; clears the query
// first per the JumpPalette precedent) instead of relying on the
// popover's native Esc, which the focused field would swallow.
import DietDesign
import SwiftUI

/// Full emoji picker. `onPick` fires once per tap; the host closes the
/// popover and routes through `store.toggleReaction` (which also files
/// the recents ring), so this view stays stateless apart from its field.
/// `onDismiss` fires on Esc with an empty query; the host closes the
/// popover without reacting.
struct ReactionPickerView: View {
    /// "" = categories mode; "recents" + catalog ids select the page.
    @State private var query = ""
    @State private var category = "recents"
    /// Roving arrow-key highlight over `current` (om-a3-keyboard).
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool
    private let recents: [String]
    let onPick: (String) -> Void
    let onDismiss: () -> Void

    init(
        recents: [String] = ReactionRecents.load(),
        query: String = "",
        category: String = "recents",
        onPick: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.recents = recents
        _query = State(initialValue: query)
        _category = State(initialValue: category)
        self.onPick = onPick
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: DietSpace.xs) {
            HStack(spacing: DietSpace.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(DietColor.textTertiaryColor)
                TextField("Search emoji", text: $query)
                    .textFieldStyle(.plain)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .focused($fieldFocused)
                    .onSubmit { pickHighlighted() }
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            }
            .padding(.horizontal, DietSpace.sm)
            .frame(minHeight: DietSize.controlHeight)
            .background(DietColor.wellColor)
            .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .stroke(DietColor.dividerColor, lineWidth: 1))
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("Category", selection: $category) {
                    Text("Recents").tag("recents")
                    ForEach(ReactionCatalog.categories, id: \.id) { c in
                        Text(c.title).tag(c.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if current.isEmpty {
                        Text(emptyHint)
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textTertiaryColor)
                            .padding(.vertical, DietSpace.lg)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 34), spacing: DietSpace.xxs)],
                            spacing: DietSpace.xxs
                        ) {
                            ForEach(Array(current.enumerated()), id: \.offset) { i, e in
                                Button { onPick(e.emoji) } label: {
                                    Text(e.emoji)
                                        .font(.system(size: DietSize.emojiMD))
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.plain)
                                .help(e.help)
                                .accessibilityLabel(e.help.isEmpty ? e.emoji : e.help)
                                .background(
                                    RoundedRectangle(cornerRadius: DietRadius.control)
                                        .fill(i == highlight
                                            ? Color(nsColor: DietColor.accent).opacity(0.15)
                                            : Color.clear))
                                .id(i)
                            }
                        }
                    }
                }
                .onChange(of: highlight) { proxy.scrollTo($0, anchor: .center) }
            }
        }
        .padding(DietSpace.sm)
        .frame(width: 322, height: 330)
        .background(DietColor.windowColor)
        .onChange(of: query) { highlight = 0 }
        .onChange(of: category) { highlight = 0 }
        .onKeyPress(.upArrow) { arrow(dx: 0, dy: -1) }
        .onKeyPress(.downArrow) { arrow(dx: 0, dy: 1) }
        .onKeyPress(.leftArrow) { arrow(dx: -1, dy: 0) }
        .onKeyPress(.rightArrow) { arrow(dx: 1, dy: 0) }
        .onKeyPress(.escape) {
            // Esc with text clears first (JumpPalette precedent); with
            // an empty query the host closes the popover. Explicit, so
            // the focused field never traps the key.
            if !query.isEmpty { query = ""; return .handled }
            onDismiss()
            return .handled
        }
    }

    /// Adaptive columns rendered for the fixed 322pt width: same
    /// minimum + spacing the LazyVGrid uses, so arrow steps match.
    private var columns: Int {
        let gridWidth = 322 - DietSpace.sm * 2
        return max(1, Int((gridWidth + DietSpace.xxs) / (34 + DietSpace.xxs)))
    }

    private func arrow(dx: Int, dy: Int) -> KeyPress.Result {
        highlight = GridNav.move(
            current: highlight, dx: dx, dy: dy,
            columns: columns, count: current.count)
        return .handled
    }

    /// Return in the field picks the highlighted cell (JumpPalette
    /// precedent: submit, not a Return key handler, so field Return
    /// never double-fires with a focused grid button's activation).
    private func pickHighlighted() {
        guard current.indices.contains(highlight) else { return }
        onPick(current[highlight].emoji)
    }

    /// Display rows: search hits while querying, else the category page.
    private var current: [(emoji: String, help: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return ReactionCatalog.search(q).map { ($0.emoji, $0.keywords) }
        }
        if category == "recents" {
            return recents.map { ($0, $0) }
        }
        return ReactionCatalog.entries(forCategory: category)?
            .map { ($0.emoji, $0.keywords) } ?? []
    }

    private var emptyHint: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "No emoji match “\(q)”." }
        if category == "recents" { return "No recent reactions — picks land here." }
        return "Nothing here."
    }
}
