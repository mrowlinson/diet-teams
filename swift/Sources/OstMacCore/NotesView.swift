// NotesView.swift — om-notes lane: OneNote tab for the conversation detail.
//
// Notebook/section pickers, page list, rendered page, append box. Page HTML
// renders through NSAttributedString's HTML importer; unparseable pages
// fall back to stripped text (never blank, never raw tags).
import SwiftUI

public struct NotesView: View {
    @ObservedObject public var store: NotesStore
    @State private var draft = ""

    public init(store: NotesStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            pickers
            Divider()
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
            Divider()
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
            if store.groupID != nil {
                Text("team notes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
            } else if store.isDemo {
                Text("DEMO")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading notes…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorHint(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(4)
                .textSelection(.enabled)
            Button("Retry") { store.open(groupID: store.groupID) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(systemImage: String, title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading sections…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noSections:
            hint(
                systemImage: "tray", title: "No sections",
                body: "This notebook has no sections yet.")
        case .browse:
            HStack(spacing: 0) {
                pageList
                Divider()
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
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.pages, selection: pageBinding) { page in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title.isEmpty ? "Untitled" : page.title)
                            .lineLimit(2)
                        if let updated = page.updated {
                            Text(ChatMessage.shortTime(updated))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(page.title.isEmpty ? "Untitled" : page.title)
                            .font(.title3).bold()
                            .textSelection(.enabled)
                        Text(Self.rendered(html: page.html))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
            } else {
                Text(Self.detailHint(
                    sectionSelected: store.selectedSectionID != nil,
                    pagesEmpty: store.pages.isEmpty))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Append

    private var appendBox: some View {
        VStack(spacing: 4) {
            if let err = store.appendError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
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
