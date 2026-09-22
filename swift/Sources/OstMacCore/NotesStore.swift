// NotesStore.swift — om-notes lane: OneNote state for the Notes tab.
//
// INPUT API (what the conversation detail drives):
//   store.open(groupID:)  — set scope (team id for channels, nil for
//                          chats = the user's own OneNote) + load notebooks
//   store.selectNotebook(_:) — load sections+pages, auto-open first page
//   store.selectSection(_:)   — auto-open the section's first page
//   store.selectPage(_:)      — load page HTML via core
//   store.append(text:)        — append a paragraph, then reload the page
// Shared models: NotebookItem/NoteSectionItem/NotePageItem (Models.swift).
import Foundation

/// Notes content state (a failed load carries its message).
public enum NotesState: Equatable, Sendable {
    /// Nothing loaded yet (or context just reset).
    case idle
    /// A fetch is in flight.
    case loading
    /// Notebooks (maybe zero) are in `notebooks`.
    case loaded
    /// Last fetch failed; associated user-facing message.
    case error(String)
}

@MainActor
public final class NotesStore: ObservableObject {
    /// Sync fetches (run off-main). Throw `CoreCallError` on core failure.
    public struct Fetchers: Sendable {
        public var notebooks: @Sendable (String?) throws -> NotebooksResponse
        public var sections: @Sendable (String, String?) throws -> NoteSectionsResponse
        public var page: @Sendable (String, String?) throws -> NotePageResponse
        public var append: @Sendable (String, String, String?) throws -> NoteAppendResponse

        public init(
            notebooks: @escaping @Sendable (String?) throws -> NotebooksResponse,
            sections: @escaping @Sendable (String, String?) throws -> NoteSectionsResponse,
            page: @escaping @Sendable (String, String?) throws -> NotePageResponse,
            append: @escaping @Sendable (String, String, String?) throws -> NoteAppendResponse
        ) {
            self.notebooks = notebooks
            self.sections = sections
            self.page = page
            self.append = append
        }

        /// Live fetchers: blocking FFI + network on a detached task.
        public static func live() -> Fetchers {
            Fetchers(
                notebooks: { try RustCore.notebooks(groupID: $0) },
                sections: { try RustCore.noteSections(notebookID: $0, groupID: $1) },
                page: { try RustCore.notePage(pageID: $0, groupID: $1) },
                append: { try RustCore.noteAppend(pageID: $0, text: $1, groupID: $2) }
            )
        }
    }

    /// Current scope: team (M365 group) id for channels, nil for chats
    /// (the user's own OneNote — chats have no shared notebook).
    @Published public private(set) var groupID: String?
    @Published public private(set) var state: NotesState = .idle
    @Published public private(set) var notebooks: [NotebookItem] = []
    @Published public private(set) var sections: [NoteSectionItem] = []
    @Published public private(set) var page: NotePageResponse?
    @Published public private(set) var appending = false
    @Published public private(set) var appendError: String?
    public private(set) var selectedNotebookID: String?
    public private(set) var selectedSectionID: String?
    public private(set) var selectedPageID: String?
    public private(set) var isDemo = false
    private var fetchers: Fetchers
    private var generation = 0

    public nonisolated init(fetchers: Fetchers = Fetchers.live()) {
        self.fetchers = fetchers
    }

    /// Pages of the selected section (empty until a section is selected).
    public var pages: [NotePageItem] {
        sections.first(where: { $0.id == selectedSectionID })?.pages ?? []
    }

    /// Open the Notes scope for a conversation: reset everything, then
    /// load notebooks. Demo stores adopt canned data instead (no core).
    public func open(groupID: String?) {
        self.groupID = groupID
        notebooks = []
        sections = []
        page = nil
        appendError = nil
        selectedNotebookID = nil
        selectedSectionID = nil
        selectedPageID = nil
        generation += 1
        if isDemo {
            notebooks = DemoData.notebooks
            state = .loaded
            if let first = notebooks.first {
                selectNotebook(first.id) // offline drill to first page
            }
            return
        }
        loadNotebooks()
    }

    /// Demo mode: canned notebooks; selection drills offline.
    public func showDemo() {
        isDemo = true
        open(groupID: nil)
    }

    public func selectNotebook(_ id: String) {
        guard id != selectedNotebookID else { return }
        selectedNotebookID = id
        selectedSectionID = nil
        selectedPageID = nil
        sections = []
        page = nil
        appendError = nil
        if isDemo {
            sections = DemoData.noteSections(for: id)
            state = .loaded
            autoOpenFirst()
            return
        }
        loadSections(notebookID: id)
    }

    public func selectSection(_ id: String) {
        guard id != selectedSectionID else { return }
        selectedSectionID = id
        selectedPageID = nil
        page = nil
        appendError = nil
        if isDemo {
            autoOpenFirst()
            return
        }
        autoOpenFirst()
    }

    public func selectPage(_ id: String) {
        guard id != selectedPageID else { return }
        selectedPageID = id
        page = nil
        appendError = nil
        if isDemo {
            page = DemoData.notePage(for: id)
            return
        }
        loadPage(pageID: id)
    }

    /// Append a paragraph, then reload the page so the new text shows.
    /// No-op for blank text or without a selected page.
    public func append(text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let id = selectedPageID, !appending else { return }
        if isDemo {
            DemoData.appendDemo(pageID: id, text: body)
            page = DemoData.notePage(for: id)
            return
        }
        appending = true
        appendError = nil
        generation += 1
        let gen = generation
        let fetchers = fetchers
        let group = groupID
        Task {
            do {
                _ = try await Task.detached {
                    try fetchers.append(id, body, group)
                }.value
                let resp = try await Task.detached {
                    try fetchers.page(id, group)
                }.value
                guard gen == generation else { return }
                appending = false
                page = resp
            } catch {
                guard gen == generation else { return }
                appending = false
                appendError = Self.message(for: error)
            }
        }
    }

    // MARK: - Loads

    private func loadNotebooks() {
        state = .loading
        generation += 1
        let gen = generation
        let fetchers = fetchers
        let group = groupID
        Task {
            do {
                let resp = try await Task.detached {
                    try fetchers.notebooks(group)
                }.value
                guard gen == generation else { return }
                notebooks = resp.notebooks
                state = .loaded
            } catch {
                guard gen == generation else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    private func loadSections(notebookID: String) {
        state = .loading
        generation += 1
        let gen = generation
        let fetchers = fetchers
        let group = groupID
        Task {
            do {
                let resp = try await Task.detached {
                    try fetchers.sections(notebookID, group)
                }.value
                guard gen == generation else { return }
                sections = resp.sections
                state = .loaded
                autoOpenFirst()
            } catch {
                guard gen == generation else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    private func loadPage(pageID: String) {
        state = .loading
        generation += 1
        let gen = generation
        let fetchers = fetchers
        let group = groupID
        Task {
            do {
                let resp = try await Task.detached {
                    try fetchers.page(pageID, group)
                }.value
                guard gen == generation else { return }
                page = resp
                state = .loaded
            } catch {
                guard gen == generation else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Drill one level: first section with pages, then its first page.
    /// Pure selection walk — the page load (or demo adopt) follows.
    private func autoOpenFirst() {
        guard selectedSectionID == nil else {
            // Section known: open its first page when none is selected.
            if selectedPageID == nil, let first = pages.first {
                selectPage(first.id)
            }
            return
        }
        guard let section = sections.first(where: { !$0.pages.isEmpty })
            ?? sections.first
        else { return }
        selectSection(section.id)
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
