// ChatListSidebar.swift — SwiftUI sidebar: chats + loading/empty/error states.
import DietDesign
import OstMacCore
import SwiftUI

/// Sidebar list of chats. Selection writes through to `model.selectedChatID`
/// for the conversation lane to consume.
public struct ChatListSidebar: View {
    @ObservedObject private var model: ChatListViewModel
    @ObservedObject private var presence: PresenceStore
    @ObservedObject private var unread: UnreadStore
    @ObservedObject private var mentions: MentionStore
    @ObservedObject private var rules: RulesStore
    @State private var searchText = ""
    @State private var mentionsOnly = false
    @State private var showHidden = false
    /// Selected folder filter (d1-folders): nil = "All chats".
    @State private var selectedFolderID: String?
    /// Folder manager sheet (folders CRUD + auto-rules editor).
    @State private var showFolderManager = false
    /// Shot hook: rule id with its editor expanded at launch.
    private let initialEditingRuleID: String?
    /// Leave/block confirm targets (om-leave-block, native alerts below).
    @State private var pendingLeave: ChatItem?
    @State private var pendingBlock: ChatItem?
    /// Last leave attempt (error-alert Retry re-runs it).
    @State private var lastLeaveID: String?
    /// Reduce Motion (om-a1-motion): state + row changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: ChatListViewModel, presence: PresenceStore = PresenceStore(),
        unread: UnreadStore = UnreadStore(),
        mentions: MentionStore = MentionStore(),
        rules: RulesStore = RulesStore(),
        initialFilter: String = "",
        initialFolderID: String? = nil,
        folderManageOpen: Bool = false,
        initialEditingRuleID: String? = nil
    ) {
        self.model = model
        self.presence = presence
        self.unread = unread
        self.mentions = mentions
        self.rules = rules
        _searchText = State(initialValue: initialFilter)
        _selectedFolderID = State(initialValue: initialFolderID)
        _showFolderManager = State(initialValue: folderManageOpen)
        self.initialEditingRuleID = initialEditingRuleID
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                VStack(spacing: DietSpace.sm) {
                    ProgressView()
                    Text("Loading chats…")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .empty:
                DietEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No chats",
                    message: "Your Teams conversations will appear here.")
                    .transition(.opacity)
            case .error(let message):
                DietEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load chats",
                    message: message,
                    actionLabel: "Retry",
                    action: { model.refresh() })
                    .transition(.opacity)
            case .loaded:
                loadedList
                    .transition(.opacity)
            }
        }
        // System-default crossfade between content states (the loaded
        // list lands softly instead of popping; instant under Reduce
        // Motion). Standard SwiftUI only.
        .animation(DietMotion.gated(reduceMotion: reduceMotion), value: model.state)
        // Native leave confirmation (om-leave-block).
        .alert(
            "Leave “\(pendingLeave?.name ?? "this chat")”?",
            isPresented: leaveConfirmShown, presenting: pendingLeave
        ) { chat in
            Button("Leave Chat", role: .destructive) { confirmLeave(chat) }
            Button("Cancel", role: .cancel) { pendingLeave = nil }
        } message: { _ in
            Text("You’ll stop receiving messages from this chat. You can’t rejoin on your own.")
        }
        // Native block confirmation (om-leave-block).
        .alert(
            "Block “\(pendingBlock?.name ?? "this user")”?",
            isPresented: blockConfirmShown, presenting: pendingBlock
        ) { chat in
            Button("Block User", role: .destructive) { confirmBlock(chat) }
            Button("Cancel", role: .cancel) { pendingBlock = nil }
        } message: { _ in
            Text("You won’t receive messages or notifications from this user. Manage blocked users in Settings.")
        }
        // Leave failure (om-leave-block): Retry re-runs, Cancel clears.
        .alert("Couldn’t Leave Chat", isPresented: leaveErrorShown) {
            Button("Retry") { retryLeave() }
            Button("Cancel", role: .cancel) { dismissLeaveError() }
        } message: {
            Text(model.leaveError ?? "Unknown error")
        }
    }

    /// Confirm bindings: shown while a target is armed.
    private var leaveConfirmShown: Binding<Bool> {
        Binding(
            get: { pendingLeave != nil },
            set: { if !$0 { pendingLeave = nil } })
    }

    private var blockConfirmShown: Binding<Bool> {
        Binding(
            get: { pendingBlock != nil },
            set: { if !$0 { pendingBlock = nil } })
    }

    /// Error alert binding: shown while the model holds a leave error.
    private var leaveErrorShown: Binding<Bool> {
        Binding(
            get: { model.leaveError != nil },
            set: { if !$0 { dismissLeaveError() } })
    }

    /// Confirmed leave: run the model's flow (row drops on success,
    /// error alert on failure — never a list refresh).
    private func confirmLeave(_ chat: ChatItem) {
        pendingLeave = nil
        lastLeaveID = chat.id
        Task { await model.leave(chatID: chat.id) }
    }

    /// Confirmed block: record + drop the row (synchronous, local-only).
    private func confirmBlock(_ chat: ChatItem) {
        pendingBlock = nil
        model.block(chatID: chat.id)
    }

    /// Re-run the failed leave (keeps the alert up on repeat failure).
    private func retryLeave() {
        guard let id = lastLeaveID else {
            dismissLeaveError()
            return
        }
        Task { await model.leave(chatID: id) }
    }

    /// Dismiss the leave error.
    private func dismissLeaveError() {
        model.clearLeaveError()
        lastLeaveID = nil
    }

    /// Filter chain: hidden → folder → text → mentions. Every stage
    /// preserves order (filtering never re-sorts — displayChats owns
    /// the order). Client-side only — never refetches the list.
    private func visibleChats(folderID: String?) -> [ChatItem] {
        var visible = ChatListFormat.filterHidden(
            model.displayChats, hiddenIDs: rules.config.hiddenChatIDs,
            showHidden: showHidden)
        visible = ChatListFormat.filterFolder(
            visible, folderID: folderID,
            rules: model.folders.rules, overrides: model.folders.overrides)
        visible = ChatListFormat.filter(visible, query: searchText)
        if mentionsOnly {
            visible = ChatListFormat.filterMentions(visible, mentionedIDs: mentions.mentionedIDs)
        }
        return visible
    }

    private var loadedList: some View {
        let visible = visibleChats(folderID: selectedFolderID)
        let queryBlank = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            DietSearchField("Filter chats", text: $searchText)
                .padding(.horizontal, DietSpace.sm)
                .padding(.vertical, DietSpace.sm)
            DietSeamH()
            folderRow
            DietSeamH()
            mentionsRow
            DietSeamH()
            hiddenRow
            DietSeamH()
            if visible.isEmpty, mentionsOnly, queryBlank {
                DietEmptyState(
                    systemImage: "at",
                    title: "No mentions",
                    message: "Threads that mention you appear here.",
                    actionLabel: "Show all chats",
                    action: { mentionsOnly = false })
            } else if visible.isEmpty, selectedFolderID != nil, queryBlank, !mentionsOnly {
                DietEmptyState(
                    systemImage: "folder",
                    title: "No chats in folder",
                    message: "Move chats here from the row menu, or add an auto-rule.",
                    actionLabel: "Show all chats",
                    action: { selectedFolderID = nil })
            } else if visible.isEmpty, !queryBlank {
                DietEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    message: "No chats match \"\(searchText)\".",
                    actionLabel: "Clear search",
                    action: { searchText = "" })
            } else {
                List(selection: $model.selectedChatID) {
                    // Explicit row identity: rows survive reorder bursts
                    // without content/position mismatch (stable ids).
                    ForEach(visible, id: \.id) { chat in
                        ChatRow(
                            chat: chat,
                            isPinned: model.isPinned(chat.id),
                            peerAvailability: chat.is_group ? nil : .some(presence.availabilityForChat(chat.id)),
                            leaving: model.leavingIDs.contains(chat.id)
                        )
                        .tag(chat.id)
                        .unreadBadge(unread.count(for: chat.id))
                        // Row menu: native items plus one Move-to-Folder
                        // submenu (d1-folders scope requires the nested
                        // Menu). Badge updates in place, list never
                        // refetches.
                        .contextMenu {
                            if model.isPinned(chat.id) {
                                Button("Unpin", systemImage: "pin.slash") {
                                    model.unpin(chat.id)
                                }
                            } else {
                                Button("Pin", systemImage: "pin") {
                                    model.pin(chat.id)
                                }
                            }
                            if unread.count(for: chat.id) > 0 {
                                Button("Mark as Read") {
                                    unread.markRead(chatID: chat.id)
                                }
                            } else {
                                Button("Mark as Unread") {
                                    unread.markUnread(chatID: chat.id)
                                }
                            }
                            // d2-alerts: 3-state level picker (All /
                            // Mentions only / Muted). Muted absolute (no
                            // banners, no unread, mentions incl); hide
                            // drops row until Show hidden restores it.
                            Menu("Notifications") {
                                ForEach(ChatNotifyLevel.allCases, id: \.self) { level in
                                    Button {
                                        rules.setLevel(chatID: chat.id, level: level)
                                    } label: {
                                        if rules.level(chatID: chat.id) == level {
                                            Label(level.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(level.displayName)
                                        }
                                    }
                                }
                            }
                            Button(rules.isHidden(chatID: chat.id) ? "Unhide" : "Hide") {
                                rules.setHidden(chatID: chat.id, hidden: !rules.isHidden(chatID: chat.id))
                            }
                            // d1-folders: manual assign (explicit wins
                            // over auto-rules; clearing re-exposes the
                            // rule match). Native Menu; the row moves
                            // with a diffed update, never a refetch.
                            Menu("Move to Folder") {
                                Button("All Chats (Remove)") {
                                    model.folders.assign(chatID: chat.id, folderID: nil)
                                }
                                if !model.folders.folders.isEmpty {
                                    Divider()
                                    ForEach(model.folders.folders) { folder in
                                        let current = model.folders.folderID(for: chat) == folder.id
                                        Button {
                                            model.folders.assign(chatID: chat.id, folderID: folder.id)
                                        } label: {
                                            Label(
                                                folder.name,
                                                systemImage: current ? "checkmark" : "folder")
                                        }
                                    }
                                }
                            }
                            // Leave/block arm the confirm alerts below.
                            if chat.is_group {
                                Button("Leave Chat…") { pendingLeave = chat }
                                    .disabled(model.leavingIDs.contains(chat.id))
                            } else {
                                Button("Block User…") { pendingBlock = chat }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // System-default row animation for bubble-to-top moves,
                // inserts, deletes, and filter changes. Keyed on row ids
                // only, so in-place preview refreshes never shimmer the
                // list. Instant under Reduce Motion. Standard SwiftUI
                // only (no custom drivers).
                .animation(DietMotion.gated(reduceMotion: reduceMotion), value: visible.map(\.id))
            }
        }
        .sheet(isPresented: $showFolderManager) {
            FolderManagerSheet(
                folders: model.folders,
                initialEditingRuleID: initialEditingRuleID)
        }
    }

    /// Folder selector row (d1-folders): native Picker (All chats +
    /// folders) plus a Manage button for the CRUD/rules sheet. Always
    /// present (stable for shots/tests). Switching filters client-side
    /// with a diffed list update — no spinner, no refetch — and the
    /// selection survives when its chat stays visible, else clears
    /// (never a blind jump).
    private var folderRow: some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: "folder")
                .font(.system(size: DietSize.iconMD))
                .foregroundStyle(DietColor.textSecondaryColor)
            Picker("Folder", selection: $selectedFolderID) {
                Text("All chats").tag(nil as String?)
                ForEach(model.folders.folders) { folder in
                    Text(folder.name).tag(folder.id as String?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("folder-picker")
            Spacer()
            Button("Manage…") { showFolderManager = true }
                .accessibilityIdentifier("folder-manage")
        }
        .padding(.horizontal, DietSpace.sm)
        .padding(.vertical, DietSpace.xs)
        .onChange(of: selectedFolderID) { next in
            model.selectedChatID = FolderResolve.selectedAfterSwitch(
                selectedID: model.selectedChatID,
                visible: visibleChats(folderID: next))
        }
    }

    /// Mentions filter row (om-mentions): stable id `mentions`. Tapping
    /// toggles the mentioning-threads filter; the count names the
    /// flagged threads. Always present (stable for shots/tests), muted
    /// at zero. Client-side only — never refetches the list.
    private var mentionsRow: some View {
        Button {
            mentionsOnly.toggle()
        } label: {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: mentionsOnly ? "at.circle.fill" : "at.circle")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(mentionsOnly ? Color.accentColor : DietColor.textSecondaryColor)
                Text("Mentions")
                    .font(DietType.headline)
                    .foregroundStyle(mentionsOnly ? DietColor.textPrimaryColor : DietColor.textSecondaryColor)
                Spacer()
                if mentions.count > 0 {
                    Text("\(mentions.count)")
                        .font(DietType.captionMono)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            .contentShape(Rectangle())
            .background(mentionsOnly ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .id("mentions")
        .accessibilityIdentifier("mentions")
        .plainFocusRing()
        .help("Show only threads that mention you")
    }

    /// Show-hidden row (om-mute-hide): stable id `show-hidden`. Tapping
    /// reveals hidden threads (hidden filter bypassed); tapping again
    /// re-hides them. Restore path: reveal, then Unhide from the row's
    /// context menu. Always present (stable for shots/tests), muted when
    /// off. Client-side only — never refetches the list. No count shown
    /// (counters live in Diagnostics only).
    private var hiddenRow: some View {
        Button {
            showHidden.toggle()
        } label: {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: showHidden ? "eye.fill" : "eye")
                    .font(.system(size: DietSize.iconMD))
                    .foregroundStyle(showHidden ? Color.accentColor : DietColor.textSecondaryColor)
                Text(showHidden ? "Showing hidden" : "Show hidden")
                    .font(DietType.headline)
                    .foregroundStyle(showHidden ? DietColor.textPrimaryColor : DietColor.textSecondaryColor)
                Spacer()
            }
            .padding(.horizontal, DietSpace.sm)
            .padding(.vertical, DietSpace.xs)
            .contentShape(Rectangle())
            .background(showHidden ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .id("show-hidden")
        .accessibilityIdentifier("show-hidden")
        .plainFocusRing()
        .help("Show hidden threads to restore them")
    }
}

/// Row right-click menu (om-leave-block): one top-level item — group
/// chats offer Leave, 1:1 chats offer Block. In-flight leaves disable
/// their item.
struct ChatRow: View {
    let chat: ChatItem
    /// User-pinned rows show a pin glyph by the timestamp.
    var isPinned: Bool = false
    /// Chatmate availability for 1:1 chats. Outer nil = group (no dot);
    /// inner nil = unknown (no dot, fail closed).
    var peerAvailability: String?? = nil
    /// Leave call in flight: a spinner replaces the preview time.
    var leaving: Bool = false

    private var dietPresence: DietPresence? {
        guard let outer = peerAvailability else { return nil }
        return DietPresence(teamsAvailability: outer)
    }

    var body: some View {
        HStack(alignment: .center, spacing: DietSpace.sm) {
            DietAvatar(
                chat.name, presence: dietPresence,
                size: DietSize.avatarMD)
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.name)
                        .font(DietType.headline)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(1)
                    Spacer()
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: DietSize.iconSM))
                            .foregroundStyle(DietColor.textTertiaryColor)
                            .accessibilityLabel("Pinned")
                    }
                    if leaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Leaving chat")
                    } else {
                        Text(ChatListFormat.previewTime(chat.last_message_time))
                            .font(DietType.captionMono)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                }
                Text(previewText)
                    .font(DietType.subheadline)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, DietSpace.xs)
        .accessibilityElement(children: .combine)
    }

    private var previewText: String {
        let line = ChatListFormat.previewLine(
            sender: chat.last_message_sender,
            preview: chat.last_message_preview)
        return line.isEmpty ? "No messages" : line
    }
}

/// Native list badge for unread counts (om-notifbadge): the system
/// `.badge(_:)` when positive, no badge at zero. Shared by the chats
/// list and the teams browser (same module).
extension View {
    @ViewBuilder
    func unreadBadge(_ count: Int) -> some View {
        if count > 0 {
            badge(count)
        } else {
            self
        }
    }

}

// MARK: - d1-folders manager sheet

/// Folders CRUD + auto-rules editor (d1-folders). Native Form in a
/// Sheet: folders rename inline (Return commits; empty/duplicate names
/// revert), delete via the row button, and one "New folder" composer;
/// rules list each rule with an enable toggle, an inline editor, and
/// delete, plus a "New rule" composer. Every write persists
/// immediately; the sidebar list updates by diff, never a refetch.
struct FolderManagerSheet: View {
    @ObservedObject var folders: FolderStore
    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""
    @State private var folderError: String?
    /// Rule id with its inline editor expanded (nil = all collapsed).
    @State private var editingRuleID: String?
    @State private var showNewRule = false

    init(folders: FolderStore, initialEditingRuleID: String? = nil) {
        self.folders = folders
        _editingRuleID = State(initialValue: initialEditingRuleID)
    }

    var body: some View {
        Form {
            Section("Folders") {
                if folders.folders.isEmpty {
                    Text("No folders yet. Unassigned chats stay in All chats.")
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                ForEach(folders.folders) { folder in
                    FolderNameRow(folders: folders, folder: folder)
                }
                HStack {
                    TextField(
                        "New folder name", text: $newFolderName,
                        prompt: Text("New folder name")
                    )
                    .labelsHidden()
                    .onSubmit(addFolder)
                    Button("Add") { addFolder() }
                        .disabled(
                            newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let folderError {
                    Text(folderError)
                        .foregroundStyle(.red)
                        .font(DietType.captionMono)
                }
            }
            Section("Auto-rules") {
                Text("First matching rule wins. Manual moves always beat rules.")
                    .foregroundStyle(DietColor.textSecondaryColor)
                if folders.rules.isEmpty {
                    Text("No rules yet.")
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                ForEach(folders.rules) { rule in
                    FolderRuleRow(
                        folders: folders, rule: rule,
                        expanded: editingRuleID == rule.id,
                        onToggleExpand: {
                            editingRuleID = editingRuleID == rule.id ? nil : rule.id
                        })
                }
                if folders.folders.isEmpty {
                    Text("Create a folder before adding rules.")
                        .foregroundStyle(DietColor.textSecondaryColor)
                } else {
                    Button("Add Rule…") { showNewRule = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showNewRule) {
            FolderRuleComposer(folders: folders)
        }
        .accessibilityIdentifier("folder-manager")
    }

    private func addFolder() {
        folderError = nil
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard folders.createFolder(name: name) != nil else {
            folderError = "That name is taken — pick another."
            return
        }
        newFolderName = ""
    }
}

/// One folder row: inline rename (Return commits, failures revert) +
/// delete. Deleting a folder also drops its rules and assignments.
private struct FolderNameRow: View {
    @ObservedObject var folders: FolderStore
    let folder: ChatFolder
    @State private var draft: String = ""

    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(DietColor.textSecondaryColor)
            TextField("Folder name", text: $draft)
                .labelsHidden()
                .onSubmit(commit)
                .onAppear { draft = folder.name }
                .onChange(of: folder.name) { draft = $0 }
            Spacer()
            Button(role: .destructive) {
                folders.deleteFolder(id: folder.id)
            } label: {
                Label("Delete folder", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
    }

    private func commit() {
        if !folders.renameFolder(id: folder.id, name: draft) {
            draft = folder.name
        }
    }
}

/// One rule row: enable toggle + summary + expandable inline editor +
/// delete. Matchers OR together; blank fields are off.
private struct FolderRuleRow: View {
    @ObservedObject var folders: FolderStore
    let rule: FolderRule
    let expanded: Bool
    let onToggleExpand: () -> Void
    @State private var draftFolderID = ""
    @State private var draftName = ""
    @State private var draftDomain = ""
    @State private var draftKind = FolderRuleKindChoice.any

    var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            HStack {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                Button(action: onToggleExpand) {
                    Text(summary)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    folders.removeRule(id: rule.id)
                } label: {
                    Label("Delete rule", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            if expanded {
                FolderRuleFields(
                    folders: folders.folders,
                    folderID: $draftFolderID,
                    namePattern: $draftName,
                    senderDomain: $draftDomain,
                    kind: $draftKind)
                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .disabled(draftFolderID.isEmpty)
                }
            }
        }
        .onAppear(perform: reset)
        .onChange(of: rule) { _ in reset() }
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { folders.setRuleEnabled(id: rule.id, enabled: $0) })
    }

    private var summary: String {
        var parts: [String] = []
        if let p = rule.namePattern, !p.isEmpty { parts.append("name “\(p)”") }
        if let d = rule.senderDomain, !d.isEmpty { parts.append("sender @\(d)") }
        if let k = rule.kind {
            parts.append(k == .group ? "group chats" : "1:1 chats")
        }
        let match = parts.isEmpty ? "never matches" : parts.joined(separator: " OR ")
        let target = folders.name(for: rule.folderID) ?? "?"
        return "→ \(target): \(match)"
    }

    private func reset() {
        draftFolderID = rule.folderID
        draftName = rule.namePattern ?? ""
        draftDomain = rule.senderDomain ?? ""
        draftKind = FolderRuleKindChoice(rule.kind)
    }

    private func save() {
        var next = rule
        next.folderID = draftFolderID
        next.namePattern = draftName
        next.senderDomain = draftDomain
        next.kind = draftKind.folderKind
        if folders.updateRule(next) { onToggleExpand() }
    }
}

/// New-rule composer sheet. The folder picker defaults to the first
/// folder; saving with all matchers blank is allowed (the rule never
/// matches until edited).
private struct FolderRuleComposer: View {
    @ObservedObject var folders: FolderStore
    @Environment(\.dismiss) private var dismiss
    @State private var folderID = ""
    @State private var namePattern = ""
    @State private var senderDomain = ""
    @State private var kind = FolderRuleKindChoice.any

    var body: some View {
        Form {
            Section("New auto-rule") {
                FolderRuleFields(
                    folders: folders.folders,
                    folderID: $folderID,
                    namePattern: $namePattern,
                    senderDomain: $senderDomain,
                    kind: $kind)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    folders.addRule(FolderRule(
                        folderID: folderID, namePattern: namePattern,
                        senderDomain: senderDomain, kind: kind.folderKind))
                    dismiss()
                }
                .disabled(folderID.isEmpty)
            }
        }
        .onAppear { folderID = folders.folders.first?.id ?? "" }
        .accessibilityIdentifier("folder-rule-composer")
    }
}

/// Shared rule fields: target folder picker, name substring/regex,
/// sender domain, chat-kind picker.
private struct FolderRuleFields: View {
    let folders: [ChatFolder]
    @Binding var folderID: String
    @Binding var namePattern: String
    @Binding var senderDomain: String
    @Binding var kind: FolderRuleKindChoice

    var body: some View {
        Picker("Folder", selection: $folderID) {
            ForEach(folders) { folder in
                Text(folder.name).tag(folder.id)
            }
        }
        TextField("Name contains (whole word; re: = regex)", text: $namePattern)
        TextField("Sender domain (e.g. contoso.com)", text: $senderDomain)
            .textContentType(.none)
            .autocorrectionDisabled()
        Picker("Chat kind", selection: $kind) {
            ForEach(FolderRuleKindChoice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// Segmented kind choices (Any = matcher off).
private enum FolderRuleKindChoice: String, CaseIterable, Identifiable {
    case any, group, direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Any"
        case .group: return "Group"
        case .direct: return "1:1"
        }
    }

    var folderKind: FolderKind? {
        switch self {
        case .any: return nil
        case .group: return .group
        case .direct: return .direct
        }
    }

    init(_ kind: FolderKind?) {
        switch kind {
        case .group: self = .group
        case .direct: self = .direct
        case nil: self = .any
        }
    }
}
