// JumpPaletteView.swift — om-cmdk lane: Cmd+K fuzzy jump-to sheet.
// Search field + ranked rows; Up/Down moves, Return jumps, Esc closes.
// om-ja-search: optional Messages scope (Graph message search hits +
// jump-to-message) behind `searchStore` + `onPickMessage`.
// om-jb-filesearch: optional Files + People sections (OneDrive +
// directory search) behind `filePeople` + pick handlers.
import DietDesign
import OstMacCore
import SwiftUI

/// Fuzzy jump-to palette. `targets` is the full row set (chats, channels,
/// teams); filtering + ranking is live via ``FuzzyMatch``. `onPick` fires
/// with the chosen target's open id + name; the host dismisses + opens.
/// `verb` retitles the Return hint when the palette is re-targeted
/// (om-msgactions forwards through this same view).
///
/// Messages scope: when `searchStore` + `onPickMessage` are both present,
/// a Chats/Messages scope chip appears; the Messages scope debounces the
/// query into `MessageSearchStore` and `onPickMessage` fires with the
/// picked hit (the host opens the chat + seeks the bubble).
/// `chatNameFor` resolves hit subtitles (nil = sender + time only).
///
/// Files + People sections: when `filePeople` and at least one pick
/// handler are present, the query also debounces into
/// `FilePeopleSearchStore` and the hits render below the main rows.
/// ↑↓/⏎ span all three sections as one flat list (om-lt4-palettenav);
/// click/tap still picks directly. The forward sheet (no store) stays
/// chats-only.
public struct JumpPaletteView: View {
    private enum Scope: String {
        case chats
        case messages
    }

    private let targets: [JumpTarget]
    private let onPick: (String, String) -> Void
    private let verb: String
    private let searchStore: MessageSearchStore?
    private let chatNameFor: ((String) -> String?)?
    private let onPickMessage: ((SearchHit) -> Void)?
    private let filePeople: FilePeopleSearchStore?
    private let onPickFile: ((SharedFile) -> Void)?
    private let onPickPerson: ((TeamMember) -> Void)?
    @State private var query = ""
    @State private var highlight = 0
    @State private var scope: Scope = .chats
    /// Bumped by store publishers below: the stores are held plain (not
    /// @ObservedObject), so without this the flat nav counts captured in
    /// `body` would go stale when async hits land between keystrokes.
    @State private var storeTick = 0
    @FocusState private var fieldFocused: Bool

    public init(
        targets: [JumpTarget], initialQuery: String = "", verb: String = "jump",
        searchStore: MessageSearchStore? = nil,
        chatNameFor: ((String) -> String?)? = nil,
        onPickMessage: ((SearchHit) -> Void)? = nil,
        filePeople: FilePeopleSearchStore? = nil,
        onPickFile: ((SharedFile) -> Void)? = nil,
        onPickPerson: ((TeamMember) -> Void)? = nil,
        onPick: @escaping (String, String) -> Void
    ) {
        self.targets = targets
        _query = State(initialValue: initialQuery)
        self.verb = verb
        self.searchStore = searchStore
        self.chatNameFor = chatNameFor
        self.onPickMessage = onPickMessage
        self.filePeople = filePeople
        self.onPickFile = onPickFile
        self.onPickPerson = onPickPerson
        self.onPick = onPick
    }

    private var matches: [JumpTarget] {
        FuzzyMatch.ranked(targets, query: query)
    }

    /// Messages scope is live only when the host wires both halves;
    /// the forward sheet (no store) stays chats-only.
    private var searchEnabled: Bool {
        searchStore != nil && onPickMessage != nil
    }

    private var inMessages: Bool {
        searchEnabled && scope == .messages
    }

    /// Debounce key: any keystroke or scope flip restarts the task.
    private var messagesQueryKey: String {
        "\(scope.rawValue)\n\(query)"
    }

    /// Sections are live only when the host wires the store plus at
    /// least one pick handler; the forward sheet stays chats-only.
    private var sectionsEnabled: Bool {
        filePeople != nil && (onPickFile != nil || onPickPerson != nil)
    }

    /// Sections render (and join the flat nav) only under a non-blank
    /// query; mirrors the `body` gate for `FilePeopleResultsView`.
    private var sectionsVisible: Bool {
        sectionsEnabled && !trimmedQuery.isEmpty
    }

    /// Flat-nav counts (om-lt4-palettenav): main rows first (chats, or
    /// message hits in Messages scope), then visible Files rows, then
    /// visible People rows. Read live off the stores at each keypress.
    private var mainCount: Int {
        inMessages ? (searchStore?.hits.count ?? 0) : matches.count
    }

    private var fileVisibleCount: Int {
        guard sectionsVisible, onPickFile != nil, let store = filePeople else { return 0 }
        return PaletteNav.visibleCount(store.files.count)
    }

    private var personVisibleCount: Int {
        guard sectionsVisible, onPickPerson != nil, let store = filePeople else { return 0 }
        return PaletteNav.visibleCount(store.people.count)
    }

    private var navTotal: Int {
        _ = storeTick
        return PaletteNav.total(
            mainCount: mainCount, fileCount: fileVisibleCount,
            personCount: personVisibleCount)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
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
                TextField(
                    inMessages ? "Search all messages" : "Jump to chat, channel, or team",
                    text: $query)
                    .textFieldStyle(.plain)
                    .font(DietType.title3)
                    .foregroundStyle(DietColor.textPrimaryColor)
                    .focused($fieldFocused)
                    .onSubmit { submit() }
                    .onChange(of: query) {
                        settleHighlight()
                        if trimmedQuery.isEmpty {
                            // Blank clears immediately (no debounce):
                            // stale hits never linger under an empty field.
                            searchStore?.clear()
                            filePeople?.clear()
                        }
                    }
                    // Deferred: at launch the sheet appears before the
                    // window is key, which eats a synchronous focus grab.
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            }
            .padding(DietSpace.md)
            if searchEnabled {
                Picker("Scope", selection: $scope) {
                    Text("Chats").tag(Scope.chats)
                    Text("Messages").tag(Scope.messages)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DietSpace.md)
                .padding(.bottom, DietSpace.sm)
                .onChange(of: scope) { settleHighlight() }
            }
            DietDividerH()
            if inMessages, let store = searchStore {
                MessageResultsView(
                    search: store, query: query,
                    highlight: $highlight, chatNameFor: chatNameFor,
                    onPickMessage: { pickMessage($0, in: store) })
                    // Refresh the flat nav counts when hits land.
                    .onReceive(store.objectWillChange) { storeTick += 1 }
            } else if matches.isEmpty {
                DietEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: emptyMessage)
                    .frame(minHeight: 160)
            } else {
                ScrollViewReader { proxy in
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
                        .id(i)
                        .listRowBackground(
                            i == highlight
                                ? Color(nsColor: DietColor.accent).opacity(0.15)
                                : Color.clear)
                    }
                    .listStyle(.plain)
                    // Explicit height: a bare min/max leaves List at its
                    // small ideal size (~3 rows); grow with the matches.
                    .frame(height: Self.listHeight(for: matches.count))
                    // Scroll-to-highlight (om-a3-keyboard): flat highlight
                    // resolves to a main row; section rows live below in
                    // the static stack, never inside this List.
                    .onChange(of: highlight) { _, new in
                        guard case .main(let m)? = PaletteNav.resolve(
                            new, mainCount: mainCount,
                            fileCount: fileVisibleCount,
                            personCount: personVisibleCount)
                        else { return }
                        proxy.scrollTo(m, anchor: .center)
                    }
                }
            }
            if sectionsVisible, let store = filePeople {
                DietDividerH()
                FilePeopleResultsView(
                    search: store,
                    onPickFile: onPickFile, onPickPerson: onPickPerson,
                    highlight: highlight, mainCount: mainCount)
                    // Refresh the flat nav counts when hits land.
                    .onReceive(store.objectWillChange) { storeTick += 1 }
            }
            DietDividerH()
            Text("↑↓ move · ⏎ \(verb) · esc close")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .padding(DietSpace.sm)
        }
        .frame(width: 460)
        .background(DietColor.windowColor)
        .onAppear { settleHighlight() }
        .onChange(of: highlight) { _, new in announce(new) }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) {
            // Esc with text clears first (spotlight behavior); the host
            // sheet still closes via its own Esc when the query is empty.
            if !query.isEmpty { query = ""; return .handled }
            return .ignored
        }
        // Debounced message search: any keystroke restarts the wait;
        // blank queries clear via onChange above (never searched).
        .task(id: messagesQueryKey) {
            guard let store = searchStore, inMessages else { return }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.search(query: q)
        }
        // Debounced file+people search: any keystroke restarts the
        // wait; blank queries clear via onChange above (never searched).
        .task(id: query) {
            guard let store = filePeople, sectionsEnabled else { return }
            let q = trimmedQuery
            guard !q.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.search(query: q)
        }
    }

    private var emptyMessage: String {
        trimmedQuery.isEmpty
            ? "No chats, channels, or teams to jump to."
            : "Nothing matches \"\(query)\". Try fewer letters."
    }

    private func move(_ delta: Int) {
        highlight = PaletteNav.moveSkipping(
            current: highlight, delta: delta, total: navTotal,
            isEnabled: isRowEnabled)
    }

    /// Settles the highlight onto the first pickable row (om-a3-keyboard):
    /// channel-less team rows render disabled, so a blind 0 can strand
    /// Return on a no-op row with no feedback.
    private func settleHighlight() {
        highlight = PaletteNav.firstEnabled(total: navTotal, isEnabled: isRowEnabled) ?? 0
    }

    /// Flat-nav row enabled state (om-a3-keyboard): main chat rows only
    /// when openable; message hits and Files/People rows always pick.
    private func isRowEnabled(_ i: Int) -> Bool {
        guard let row = PaletteNav.resolve(
            i, mainCount: mainCount,
            fileCount: fileVisibleCount, personCount: personVisibleCount)
        else { return false }
        switch row {
        case .main(let m):
            if inMessages { return true }
            return matches.indices.contains(m) && matches[m].openID != nil
        case .file, .person:
            return true
        }
    }

    /// VoiceOver announcement for the roved row (om-a3-keyboard): focus
    /// stays in the field while the highlight moves, so without this
    /// VO users never learn which row is hot.
    private func announce(_ i: Int) {
        guard let label = labelForRow(i) else { return }
        AccessibilityNotification.Announcement(label).post()
    }

    private func labelForRow(_ i: Int) -> String? {
        guard let row = PaletteNav.resolve(
            i, mainCount: mainCount,
            fileCount: fileVisibleCount, personCount: personVisibleCount)
        else { return nil }
        switch row {
        case .main(let m):
            if inMessages {
                guard let store = searchStore, store.hits.indices.contains(m)
                else { return nil }
                let preview = store.hits[m].preview
                return preview.isEmpty ? "(attachment)" : preview
            }
            guard matches.indices.contains(m) else { return nil }
            return "\(matches[m].title), \(matches[m].subtitle)"
        case .file(let f):
            guard let store = filePeople, store.files.indices.contains(f)
            else { return nil }
            return store.files[f].name
        case .person(let p):
            guard let store = filePeople, store.people.indices.contains(p)
            else { return nil }
            return store.people[p].displayName
        }
    }

    /// Return: resolves the flat highlight across main + Files + People.
    /// Main rows keep their old behavior (chats pick immediately;
    /// messages search first when the query outruns the debounce, else
    /// pick the highlighted hit); section rows pick directly.
    private func submit() {
        guard let row = PaletteNav.resolve(
            highlight, mainCount: mainCount,
            fileCount: fileVisibleCount, personCount: personVisibleCount)
        else { return }
        switch row {
        case .main(let i):
            submitMain(i)
        case .file(let i):
            pickFile(i)
        case .person(let i):
            pickPerson(i)
        }
    }

    private func submitMain(_ i: Int) {
        guard inMessages, let store = searchStore else {
            pick(i)
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if q != store.lastQuery || store.isSearching {
            Task { await store.search(query: q) }
        } else {
            pickMessage(i, in: store)
        }
    }

    private func pick(_ i: Int) {
        guard matches.indices.contains(i), let id = matches[i].openID else { return }
        onPick(id, matches[i].openName)
    }

    private func pickFile(_ i: Int) {
        guard let store = filePeople, store.files.indices.contains(i) else { return }
        onPickFile?(store.files[i])
    }

    private func pickPerson(_ i: Int) {
        guard let store = filePeople, store.people.indices.contains(i) else { return }
        onPickPerson?(store.people[i])
    }

    private func pickMessage(_ i: Int, in store: MessageSearchStore) {
        guard store.hits.indices.contains(i) else { return }
        onPickMessage?(store.hits[i])
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

/// Messages-scope results (om-ja-search): server-ranked hit rows +
/// paging footer. Owned by the palette; the host passes its store.
private struct MessageResultsView: View {
    @ObservedObject var search: MessageSearchStore
    let query: String
    @Binding var highlight: Int
    let chatNameFor: ((String) -> String?)?
    let onPickMessage: (Int) -> Void

    var body: some View {
        if search.isSearching, search.hits.isEmpty {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Searching messages…")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                Spacer()
            }
            .padding(.vertical, DietSpace.xl)
            .frame(minHeight: 160)
        } else if let err = search.error, search.hits.isEmpty {
            DietEmptyState(
                systemImage: "wifi.exclamationmark",
                title: "Couldn't search messages",
                message: err,
                actionLabel: "Try Again",
                action: { search.retry() })
                .frame(minHeight: 160)
        } else if search.hits.isEmpty {
            DietEmptyState(
                systemImage: "magnifyingglass",
                title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Search messages" : "No matches",
                message: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Type above to search every chat and channel."
                    : "Nothing matches \"\(query)\". Try fewer words.")
                .frame(minHeight: 160)
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(0 ..< search.hits.count, id: \.self) { i in
                        let hit = search.hits[i]
                        Button {
                            onPickMessage(i)
                        } label: {
                        HStack(spacing: DietSpace.sm) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: DietSize.iconMD))
                                .foregroundStyle(DietColor.textSecondaryColor)
                                .frame(width: DietSize.iconLG)
                            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                                Text(hit.preview.isEmpty ? "(attachment)" : hit.preview)
                                    .font(DietType.body)
                                    .foregroundStyle(DietColor.textPrimaryColor)
                                    .lineLimit(2)
                                Text(subtitle(for: hit))
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
                    .frame(height: JumpPaletteView.listHeight(for: search.hits.count))
                    // Scroll-to-highlight (om-a3-keyboard).
                    .onChange(of: highlight) { _, new in
                        guard search.hits.indices.contains(new) else { return }
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
                if search.total != nil || search.more || search.loadingMore {
                    HStack(spacing: DietSpace.sm) {
                        if let total = search.total {
                            Text("\(search.hits.count) of \(total)")
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                        }
                        Spacer(minLength: DietSpace.sm)
                        if search.loadingMore {
                            ProgressView().controlSize(.small)
                        } else if search.canLoadMore {
                            Button("Load more") {
                                Task { await search.loadMore() }
                            }
                            .buttonStyle(.link)
                            .font(DietType.caption1)
                        }
                    }
                    .padding(.horizontal, DietSpace.md)
                    .padding(.vertical, DietSpace.xs)
                }
                // Mid-chain failure keeps the loaded hits; the error
                // surfaces inline with a retry for the same window.
                if let err = search.error {
                    HStack(spacing: DietSpace.sm) {
                        Text(err)
                            .font(DietType.caption1)
                            .foregroundStyle(Color(nsColor: DietColor.danger))
                            .lineLimit(1)
                        Spacer(minLength: DietSpace.sm)
                        Button("Retry") {
                            Task { await search.loadMore() }
                        }
                        .buttonStyle(.link)
                        .font(DietType.caption1)
                    }
                    .padding(.horizontal, DietSpace.md)
                    .padding(.vertical, DietSpace.xs)
                }
            }
        }
    }

    private func subtitle(for hit: SearchHit) -> String {
        var parts: [String] = []
        if !hit.sender.isEmpty { parts.append(hit.sender) }
        if let name = chatNameFor?(hit.chatID)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            parts.append(name)
        }
        parts.append(hit.displayTime)
        return parts.joined(separator: " · ")
    }
}

/// Files + People sections (om-jb-filesearch): server-ranked rows under
/// the main matches, 5 per section with an overflow note. Owned by the
/// palette; the host passes its store + pick handlers. Rows join the
/// flat ↑↓/⏎ nav (om-lt4-palettenav) via `highlight` + `mainCount` and
/// stay click/tap-able; a failed section shows an inline retry while
/// the other section keeps its rows.
private struct FilePeopleResultsView: View {
    @ObservedObject var search: FilePeopleSearchStore
    let onPickFile: ((SharedFile) -> Void)?
    let onPickPerson: ((TeamMember) -> Void)?
    /// Flat highlight over main + Files + People (see ``PaletteNav``).
    let highlight: Int
    /// Main-section row count: the flat base the Files rows start at.
    let mainCount: Int

    /// Visible Files rows (flat nav + highlight base for People).
    private var fileVisible: Int {
        onPickFile == nil ? 0 : PaletteNav.visibleCount(search.files.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            if onPickFile != nil {
                sectionHeader(title: "Files", spinning: search.isSearching && search.files.isEmpty)
                if let err = search.fileError, search.files.isEmpty {
                    sectionError(message: err) { search.retry() }
                } else {
                    ForEach(Array(search.files.prefix(PaletteNav.sectionRowCap).enumerated()), id: \.element.id) { j, file in
                        Button { onPickFile?(file) } label: {
                            HStack(spacing: DietSpace.sm) {
                                Image(systemName: file.isFolder ? "folder" : file.iconName)
                                    .font(.system(size: DietSize.iconMD))
                                    .foregroundStyle(DietColor.textSecondaryColor)
                                    .frame(width: DietSize.iconLG)
                                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                                    Text(file.name)
                                        .font(DietType.body)
                                        .foregroundStyle(DietColor.textPrimaryColor)
                                        .lineLimit(1)
                                    Text(file.isFolder ? "Folder" : file.sizeLabel)
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
                        .background(
                            RoundedRectangle(cornerRadius: DietRadius.control)
                                .fill(highlight == mainCount + j
                                    ? Color(nsColor: DietColor.accent).opacity(0.15)
                                    : Color.clear))
                    }
                    overflowNote(count: search.files.count)
                }
            }
            if onPickPerson != nil {
                sectionHeader(title: "People", spinning: search.isSearching && search.people.isEmpty)
                if let err = search.peopleError, search.people.isEmpty {
                    sectionError(message: err) { search.retry() }
                } else {
                    ForEach(Array(search.people.prefix(PaletteNav.sectionRowCap).enumerated()), id: \.element.id) { k, person in
                        Button { onPickPerson?(person) } label: {
                            HStack(spacing: DietSpace.sm) {
                                Image(systemName: "person.circle")
                                    .font(.system(size: DietSize.iconMD))
                                    .foregroundStyle(DietColor.textSecondaryColor)
                                    .frame(width: DietSize.iconLG)
                                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                                    Text(person.displayName)
                                        .font(DietType.body)
                                        .foregroundStyle(DietColor.textPrimaryColor)
                                        .lineLimit(1)
                                    Text(person.email ?? "No email")
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
                        .background(
                            RoundedRectangle(cornerRadius: DietRadius.control)
                                .fill(highlight == mainCount + fileVisible + k
                                    ? Color(nsColor: DietColor.accent).opacity(0.15)
                                    : Color.clear))
                    }
                    overflowNote(count: search.people.count)
                }
            }
        }
        .padding(.horizontal, DietSpace.md)
        .padding(.vertical, DietSpace.sm)
    }

    private func sectionHeader(title: String, spinning: Bool) -> some View {
        HStack(spacing: DietSpace.xs) {
            Text(title.uppercased())
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textTertiaryColor)
            if spinning { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .padding(.top, DietSpace.xs)
    }

    private func sectionError(message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Color(nsColor: DietColor.danger))
            Text(message)
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
                .lineLimit(2)
            Spacer(minLength: DietSpace.sm)
            Button("Try Again", action: retry)
                .buttonStyle(.dietSecondary)
                .controlSize(.small)
        }
        .padding(.vertical, DietSpace.xs)
    }

    /// "+N more" when the section overflows the row cap (nil otherwise).
    @ViewBuilder
    private func overflowNote(count: Int) -> some View {
        if count > PaletteNav.sectionRowCap {
            HStack {
                Text("+\(count - PaletteNav.sectionRowCap) more")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textTertiaryColor)
                Spacer(minLength: 0)
            }
            .padding(.bottom, DietSpace.xs)
        }
    }
}
