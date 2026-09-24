// NotesView.swift — om-notes lane: OneNote tab for the conversation detail.
//
// Notebook/section pickers, page list, rendered page, append box. Page HTML
// renders through NSAttributedString's HTML importer; unparseable pages
// fall back to stripped text (never blank, never raw tags).
import DietDesign
import SwiftUI
import DietDesign

public struct NotesView: View {
    @ObservedObject public var store: NotesStore
    @State private var draft = ""

    public init(store: NotesStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            pickers
            DietSeamH()
            switch store.state {
            case .idle:
                idleHint
            case .loading where store.page == nil && store.notebooks.isEmpty:
                loadingHint
            case .error(let message):
                errorHint(message)
            default:
                content
            }
            DietSeamH()
            appendBox
        }
        .frame(minWidth: 380, minHeight: 480)
    }

    // MARK: - Pickers

    private var pickers: some View {
        HStack {
            Picker("Notebook", selection: notebookBinding) {
                if store.notebooks.isEmpty {
                    Text("No notebooks").tag(nil as String?)
                }
                ForEach(store.notebooks) { nb in
                    Text(nb.name).tag(nb.id as String?)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            Picker("Section", selection: sectionBinding) {
                if store.sections.isEmpty {
                    Text("No sections").tag(nil as String?)
                }
                ForEach(store.sections) { section in
                    Text(section.name).tag(section.id as String?)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            Spacer()
            // No DEMO badge here: the conversation header already shows it
            // (this tab doubled it — the only tab that did).
            if store.groupID != nil {
                Text("team notes")
                    .font(DietType.caption2)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .padding(.horizontal, DietSpace.xs).padding(.vertical, DietSpace.xxs)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, DietSpace.sm)
    }

    private var notebookBinding: Binding<String?> {
        Binding(
            get: { store.selectedNotebookID },
            set: { if let id = $0 { store.selectNotebook(id) } }
        )
    }

    private var sectionBinding: Binding<String?> {
        Binding(
            get: { store.selectedSectionID },
            set: { if let id = $0 { store.selectSection(id) } }
        )
    }

    // MARK: - States

    private var idleHint: some View {
        hint(
            systemImage: "note.text", title: "Notes",
            body: "Select a conversation to browse its notebooks.")
    }

    private var loadingHint: some View {
        VStack(spacing: DietSpace.row) {
            ProgressView().controlSize(.small)
            Text("Loading notes…").foregroundStyle(DietColor.textSecondaryColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorHint(_ message: String) -> some View {
        DietEmptyState(
            systemImage: "exclamationmark.triangle",
            title: "Couldn't load notes",
            message: message,
            actionLabel: "Retry",
            action: { store.open(groupID: store.groupID) })
    }

    private func hint(systemImage: String, title: String, body: String) -> some View {
        DietEmptyState(systemImage: systemImage, title: title, message: body)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch Self.contentState(
            notebooksEmpty: store.notebooks.isEmpty,
            sectionsEmpty: store.sections.isEmpty,
            loading: store.state == .loading
        ) {
        case .noNotebooks:
            hint(
                systemImage: "note.text", title: "No notebooks",
                body: Self.noNotebooksBody(groupID: store.groupID))
        case .loadingSections:
            VStack(spacing: DietSpace.row) {
                ProgressView().controlSize(.small)
                Text("Loading sections…").foregroundStyle(DietColor.textSecondaryColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noSections:
            hint(
                systemImage: "tray", title: "No sections",
                body: "This notebook has no sections yet.")
        case .browse:
            HStack(spacing: 0) {
                pageList
                DietDividerV()
                pageDetail
            }
        }
    }

    private var pageList: some View {
        Group {
            if store.pages.isEmpty {
                Text(
                    store.selectedSectionID == nil
                        ? "Select a section." : "No pages in this section."
                )
                .foregroundStyle(DietColor.textSecondaryColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.pages, selection: pageBinding) { page in
                    VStack(alignment: .leading, spacing: DietSpace.xxs) {
                        Text(page.title.isEmpty ? "Untitled" : page.title)
                            .lineLimit(2)
                        if let updated = page.updated {
                            Text(ChatMessage.shortTime(updated))
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                        }
                    }
                    .tag(page.id)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
    }

    private var pageBinding: Binding<String?> {
        Binding(
            get: { store.selectedPageID },
            set: { if let id = $0 { store.selectPage(id) } }
        )
    }

    private var pageDetail: some View {
        Group {
            if let page = store.page {
                ScrollView {
                    VStack(alignment: .leading, spacing: DietSpace.row) {
                        Text(page.title.isEmpty ? "Untitled" : page.title)
                            .font(DietType.title3).bold()
                            .textSelection(.enabled)
                        Text(Self.rendered(html: page.html))
                            .font(DietType.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
            } else {
                Text(Self.detailHint(
                    sectionSelected: store.selectedSectionID != nil,
                    pagesEmpty: store.pages.isEmpty))
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Append

    private var appendBox: some View {
        VStack(spacing: DietSpace.xs) {
            if let err = store.appendError {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack {
                TextField("Append a paragraph…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitAppend() }
                    .disabled(store.selectedPageID == nil || store.appending)
                if store.appending {
                    ProgressView().controlSize(.small)
                }
                Button("Append") { submitAppend() }
                    .disabled(
                        store.selectedPageID == nil || store.appending
                            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func submitAppend() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        store.append(text: body)
    }

    // MARK: - Content state (pure, testable)

    /// Loaded-view bucket: empty levels get their own honest state instead
    /// of the browse prompts ("Select a notebook…" with zero notebooks).
    public enum NotesContent: Equatable, Sendable {
        case noNotebooks
        case loadingSections
        case noSections
        case browse
    }

    public nonisolated static func contentState(
        notebooksEmpty: Bool, sectionsEmpty: Bool, loading: Bool
    ) -> NotesContent {
        if notebooksEmpty { return .noNotebooks }
        if sectionsEmpty { return loading ? .loadingSections : .noSections }
        return .browse
    }

    /// Scope-aware empty body: team channels read the team notebook, plain
    /// chats read the user's own OneNote.
    public nonisolated static func noNotebooksBody(groupID: String?) -> String {
        groupID == nil
            ? "You have no OneNote notebooks yet."
            : "This team has no OneNote notebooks yet."
    }

    /// Detail prompt when no page is loaded: only "Select a page." when
    /// pages exist to select.
    public nonisolated static func detailHint(sectionSelected: Bool, pagesEmpty: Bool) -> String {
        if !sectionSelected { return "Select a section to browse its pages." }
        if pagesEmpty { return "This section has no pages." }
        return "Select a page."
    }

    // MARK: - HTML render

    /// Page HTML → display text. Prefers the HTML importer (headings, bold,
    /// lists survive); falls back to stripped text when the import fails.
    /// Pure and testable; never returns raw tags.
    public nonisolated static func rendered(html: String) -> AttributedString {
        if let data = html.data(using: .utf8),
           let imported = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ),
           let attr = try? AttributedString(imported, including: \.foundation)
        {
            return attr
        }
        return AttributedString(MessageRender.stripTags(html))
    }
}
