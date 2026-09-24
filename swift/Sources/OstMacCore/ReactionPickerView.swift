// ReactionPickerView.swift — om-react-polish: the more-picker grid
// (search + recents + categories) shown in a transient popover from the
// menu row's ＋ button. Native controls only: text field, segmented
// categories, plain buttons in a lazy grid.
import DietDesign
import SwiftUI

/// Full emoji picker. `onPick` fires once per tap; the host closes the
/// popover and routes through `store.toggleReaction` (which also files
/// the recents ring), so this view stays stateless apart from its field.
struct ReactionPickerView: View {
    /// "" = categories mode; "recents" + catalog ids select the page.
    @State private var query = ""
    @State private var category = "recents"
    private let recents: [String]
    let onPick: (String) -> Void

    init(
        recents: [String] = ReactionRecents.load(),
        query: String = "",
        category: String = "recents",
        onPick: @escaping (String) -> Void
    ) {
        self.recents = recents
        _query = State(initialValue: query)
        _category = State(initialValue: category)
        self.onPick = onPick
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
                        ForEach(current, id: \.emoji) { e in
                            Button { onPick(e.emoji) } label: {
                                Text(e.emoji)
                                    .font(.system(size: DietSize.emojiMD))
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .help(e.help)
                        }
                    }
                }
            }
        }
        .padding(DietSpace.sm)
        // Minimums, not fixed: the popover grows with larger text.
        .frame(minWidth: 322, minHeight: 330)
        .background(DietColor.windowColor)
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
