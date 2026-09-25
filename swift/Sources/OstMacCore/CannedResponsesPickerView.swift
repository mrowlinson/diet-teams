// CannedResponsesPickerView.swift — e2-canned: template picker popover.
//
// MentionPickerView precedent: filter field + rows, arrow-key roving
// highlight via GridNav, Esc-clears-first, onPick → host inserts into
// the draft + dismisses (insert is draft-local: zero-refresh).
import DietDesign
import SwiftUI

/// Template picker popover: filter field + template rows (title + body
/// preview). `onPick` fires with the picked template; the host inserts
/// its body into the draft and dismisses the popover.
public struct CannedResponsesPickerView: View {
    private let templates: [CannedTemplate]
    private let onPick: (CannedTemplate) -> Void
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    public init(templates: [CannedTemplate], onPick: @escaping (CannedTemplate) -> Void) {
        self.templates = templates
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DietSpace.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DietColor.textSecondaryColor)
                TextField("Templates…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(DietType.body)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .focused($fieldFocused)
                    .onSubmit { pickHighlighted() }
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            }
            .padding(DietSpace.sm)
            DietSeamH()
            let rows = CannedResponses.filtered(templates, query: query)
            if templates.isEmpty {
                emptyState(
                    systemImage: "doc.text",
                    title: "No templates yet",
                    message: "Create them in Settings → Templates.")
            } else if rows.isEmpty {
                emptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No template matches \"\(query)\".")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, template in
                                Button { onPick(template) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.title)
                                            .font(DietType.body)
                                            .foregroundStyle(DietColor.textPrimaryColor)
                                            .lineLimit(1)
                                        Text(template.body)
                                            .font(DietType.caption1)
                                            .foregroundStyle(DietColor.textSecondaryColor)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, DietSpace.sm)
                                    .padding(.vertical, DietSpace.xs)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Insert template \(template.title)")
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
        .frame(minWidth: 280, minHeight: 300)
        .onChange(of: query) { highlight = 0 }
        .onKeyPress(.upArrow) {
            highlight = GridNav.move(
                current: highlight, dx: 0, dy: -1, columns: 1,
                count: CannedResponses.filtered(templates, query: query).count)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlight = GridNav.move(
                current: highlight, dx: 0, dy: 1, columns: 1,
                count: CannedResponses.filtered(templates, query: query).count)
            return .handled
        }
        .onKeyPress(.escape) {
            if !query.isEmpty { query = ""; return .handled }
            return .ignored
        }
    }

    private func pickHighlighted() {
        let rows = CannedResponses.filtered(templates, query: query)
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
