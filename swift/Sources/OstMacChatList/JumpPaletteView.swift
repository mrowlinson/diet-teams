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
/// `FilePeopleSearchStore` and the hits render below the chat rows
/// (click/tap to pick; arrow keys stay on the chat rows). The forward
/// sheet (no store) stays chats-only.
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
                        highlight = 0
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
                .onChange(of: scope) { highlight = 0 }
            }
            DietDividerH()
            if inMessages, let store = searchStore {
                MessageResultsView(
                    search: store, query: query,
                    highlight: $highlight, chatNameFor: chatNameFor,
                    onPickMessage: { pickMessage($0, in: store) })
            } else if matches.isEmpty {
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
            if sectionsEnabled, let store = filePeople, !trimmedQuery.isEmpty {
                DietDividerH()
                FilePeopleResultsView(
                    search: store,
                    onPickFile: onPickFile, onPickPerson: onPickPerson)
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
        let count = inMessages ? (searchStore?.hits.count ?? 0) : matches.count
        guard count > 0 else { return }
        highlight = min(max(highlight + delta, 0), count - 1)
    }

    /// Return: chats pick immediately; messages search first when the
    /// query outruns the debounce, else pick the highlighted hit.
    private func submit() {
        guard inMessages, let store = searchStore else {
            pick(highlight)
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if q != store.lastQuery || store.isSearching {
            Task { await store.search(query: q) }
        } else {
            pickMessage(highlight, in: store)
        }
    }

    private func pick(_ i: Int) {
        guard matches.indices.contains(i), let id = matches[i].openID else { return }
        onPick(id, matches[i].openName)
    }

    private func pickMessage(_ i: Int, in store: MessageSearchStore) {
        guard store.hits.indices.contains(i) else { return }
        onPickMessage?(store.hits[i])
    }

    private func icon(for kind: JumpTarget.Kind) -> String {
        switch kind {
        case .chat: "bubble.left.and.bubble.right"
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
                    .listRowBackground(
                        i == highlight
                            ? Color(nsColor: DietColor.accent).opacity(0.15)
                            : Color.clear)
                }
                .listStyle(.plain)
                .frame(height: JumpPaletteView.listHeight(for: search.hits.count))
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
/// the chat matches, 5 per section with an overflow note. Owned by the
/// palette; the host passes its store + pick handlers. Section rows are
/// click/tap (arrow keys stay on the chat rows); a failed section shows
/// an inline retry while the other section keeps its rows.
private struct FilePeopleResultsView: View {
    @ObservedObject var search: FilePeopleSearchStore
    let onPickFile: ((SharedFile) -> Void)?
    let onPickPerson: ((TeamMember) -> Void)?

    /// Rows shown per section before the "+N more" note.
    static let rowCap = 5

    var body: some View {
        VStack(spacing: 0) {
            if onPickFile != nil {
                sectionHeader(title: "Files", spinning: search.isSearching && search.files.isEmpty)
                if let err = search.fileError, search.files.isEmpty {
                    sectionError(message: err) { search.retry() }
                } else {
                    ForEach(search.files.prefix(Self.rowCap)) { file in
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
                    }
                    overflowNote(count: search.files.count)
                }
            }
            if onPickPerson != nil {
                sectionHeader(title: "People", spinning: search.isSearching && search.people.isEmpty)
                if let err = search.peopleError, search.people.isEmpty {
                    sectionError(message: err) { search.retry() }
                } else {
                    ForEach(search.people.prefix(Self.rowCap)) { person in
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
        if count > Self.rowCap {
            HStack {
                Text("+\(count - Self.rowCap) more")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textTertiaryColor)
                Spacer(minLength: 0)
            }
            .padding(.bottom, DietSpace.xs)
        }
    }
}
