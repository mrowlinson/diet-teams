// MentionCompose.swift — om-mentions lane: @-mention composer picker.
//
// No core members API exists, so the thread roster is mined client-side:
// distinct senders from the loaded thread, most-recent first. The picker
// is a native popover (GIF-picker precedent): an @ button in the send box
// lists the roster with a filter field; tapping inserts `@Name ` into the
// draft (plain text — the send path is untouched).
import DietDesign
import SwiftUI

/// Pure compose helpers: roster mining, query filtering, draft insertion.
public enum MentionCompose {
    /// Thread roster: distinct non-blank senders, most-recent first
    /// (last speaker tops the list). `excluding` drops one name
    /// (the composer — self-mentions notify nobody), matched trimmed
    /// and case-insensitively. Order is deterministic: reverse-walk,
    /// first sighting wins.
    public static func roster(from messages: [ChatMessage], excluding ownName: String? = nil) -> [String] {
        let skip = ownName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = []
        var out: [String] = []
        for m in messages.reversed() {
            let name = m.sender.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            if let skip, !skip.isEmpty, key == skip { continue }
            seen.insert(key)
            out.append(name)
        }
        return out
    }

    /// Case-insensitive substring filter over the roster. Blank query
    /// returns the roster in order.
    public static func filtered(_ roster: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return roster }
        return roster.filter { $0.lowercased().contains(q) }
    }

    /// Insert `@Name ` into the draft: empty drafts start with the token,
    /// non-empty drafts gain exactly one separating space, and the token
    /// always trails one space so typing continues naturally. Blank
    /// names leave the draft untouched.
    public static func insert(_ name: String, into draft: String) -> String {
        let bare = Mentions.bareName(name)
        guard !bare.isEmpty else { return draft }
        let token = "@\(bare) "
        if draft.isEmpty { return token }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") || draft.hasSuffix("\t")
            ? draft + token
            : draft + " " + token
    }
}

/// @-mention picker popover: filter field + roster rows. `onPick` fires
/// with the tapped name; the host inserts it into the draft and
/// dismisses the popover (GIF-picker precedent).
public struct MentionPickerView: View {
    private let roster: [String]
    private let onPick: (String) -> Void
    @State private var query = ""
    /// Roving arrow-key highlight over the filtered rows (om-a3-keyboard).
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    public init(roster: [String], onPick: @escaping (String) -> Void) {
        self.roster = roster
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DietSpace.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DietColor.textSecondaryColor)
                TextField("Mention…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .focused($fieldFocused)
                    .onSubmit { pickHighlighted() }
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            }
            .padding(DietSpace.sm)
            DietSeamH()
            let rows = MentionCompose.filtered(roster, query: query)
            if roster.isEmpty {
                emptyState(
                    systemImage: "at",
                    title: "No one to mention yet",
                    message: "Names appear here once the thread has messages.")
            } else if rows.isEmpty {
                emptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No one matches \"\(query)\".")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element) { i, name in
                                Button { onPick(name) } label: {
                                    HStack(spacing: DietSpace.sm) {
                                        DietAvatar(name, size: DietSize.avatarSM)
                                        Text("@\(name)")
                                            .font(DietType.body)
                                            .foregroundStyle(DietColor.textPrimaryColor)
                                            .lineLimit(1)
                                        Spacer(minLength: DietSpace.sm)
                                    }
                                    .padding(.horizontal, DietSpace.sm)
                                    .padding(.vertical, DietSpace.xs)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Mention \(name)")
                                .background(
                                    RoundedRectangle(cornerRadius: DietRadius.control)
                                        .fill(i == highlight
                                            ? Color(nsColor: DietColor.accent).opacity(0.15)
                                            : Color.clear))
                                .id(i)
                            }
                        }
                        .padding(.vertical, DietSpace.xs)
                    }
                    .onChange(of: highlight) { proxy.scrollTo($0, anchor: .center) }
                }
            }
        }
        // Minimums, not fixed: the popover grows with larger text.
        .frame(minWidth: 280, minHeight: 300)
        .onChange(of: query) { highlight = 0 }
        .onKeyPress(.upArrow) {
            highlight = GridNav.move(
                current: highlight, dx: 0, dy: -1, columns: 1,
                count: MentionCompose.filtered(roster, query: query).count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlight = GridNav.move(
                current: highlight, dx: 0, dy: 1, columns: 1,
                count: MentionCompose.filtered(roster, query: query).count)
            return .handled
        }
        .onKeyPress(.escape) {
            // Esc with text clears first (JumpPalette precedent); with
            // an empty query the transient popover dismisses natively.
            if !query.isEmpty { query = ""; return .handled }
            return .ignored
        }
    }

    /// Return in the field picks the highlighted row (JumpPalette
    /// precedent: submit, so field Return never double-fires with a
    /// focused row button's native activation).
    private func pickHighlighted() {
        let rows = MentionCompose.filtered(roster, query: query)
        guard rows.indices.contains(highlight) else { return }
        onPick(rows[highlight])
    }

    private func emptyState(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: DietSpace.xs) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(DietColor.textSecondaryColor)
            Text(title)
                .font(DietType.headline)
                .foregroundStyle(DietColor.textPrimaryColor)
            Text(message)
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
                .multilineTextAlignment(.center)
        }
        .padding(DietSpace.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
