// SettingsView.swift — om-settings-org lane: sidebar categories.
//
// macOS 14 native idiom: NavigationSplitView with a sidebar list of
// categories + detail forms. Every row stays wired to real behavior
// (see the om-settings-trim contract below); the refactor only
// regroups the same sections:
//   Account: status, Accounts, Sign in (live only).
//   Notifications: banners, Keyword alerts, Quiet hours, DND,
//     Focus sync, Presence schedules (the Attention surface).
//   Chats: Per-chat overrides, Blocked users, Translation,
//     Appearance (density), Templates (message templates, composer
//     picker source).
//   Calls: echo-bot test call (shared slot).
//   Summaries: Thread catch-up (provider picker + BYO key).
//   GIFs: KLIPY key (keychain).
//   Advanced: Diagnostics window link.
// Kept from om-settings-trim (every row wired to real behavior):
// Account status (gate one-liner), Sign in (shared AuthViewModel),
// Notifications (banner, preview and sound toggles, persisted),
// Per-chat overrides (mute toggles per chat, persisted in rules.json
// and enforced by the rules engine), GIFs KLIPY key (keychain;
// picker reads the same key), Thread catch-up (CatchUpStore; Base
// URL hides when the CLI provider ignores it), Calls (echo-bot test
// call via CallStore.echoLive, shared slot).
// Removed: Application (dup of About), Diagnostics (moved to the
// Diagnostics window — Window ▸ Diagnostics; Advanced links it).
import DietDesign
import OstMacChatList
import OstMacCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var auth: AuthViewModel
    @ObservedObject private var catchUp: CatchUpStore
    @ObservedObject private var notifs: MessageNotifications
    @ObservedObject private var rules: RulesStore
    /// Roster store, observed live (read-only; never triggers a
    /// chat-list refresh). Ticks without an AppState forward.
    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var quiet: QuietHoursStore
    /// Focus sync + presence schedules (e2-attention: the Attention
    /// surface — these sections sit next to Quiet hours / DND).
    @ObservedObject private var focus: FocusSyncStore
    @ObservedObject private var sched: PresenceScheduleStore
    @ObservedObject private var blocked: BlockedStore
    @ObservedObject private var accounts: AccountStore
    /// Shared call slot (place test call reuses CallStore.echoLive).
    @ObservedObject private var call: CallStore
    /// Sidebar selection (shot hooks preselect; real launches open
    /// on Account — see SettingsRouting.initialCategory).
    @State private var selection: SettingsCategory = SettingsRouting.initialCategory(
        args: CommandLine.arguments)
    @Environment(\.openWindow) private var openWindow
    /// Message templates (e2-canned): composer picker + Chats section.
    @ObservedObject private var canned: CannedResponsesStore
    /// Ghost mode (f1-ghost): read-privacy toggles (Notifications).
    @ObservedObject private var ghost: GhostStore
    /// Message density (f2-density): Comfortable/Compact (Chats →
    /// Appearance). Bound live; flips re-layout instantly.
    @ObservedObject private var density: DensityStore
    private let onAccountAdded: (AuthViewModel) -> Void
    private let onRemoveAccount: (String) -> Void
    @State private var pendingAddVM: AuthViewModel?
    @State private var showAddAccount = false
    @State private var removeCandidate: AccountRecord?
    /// KLIPY BYO key, keychain-backed (never UserDefaults). Loaded on
    /// appear, saved on every edit (blank clears).
    @State private var klipyAPIKey = ""
    /// Keyword drafts + refusal text (Settings-local: edits never touch
    /// the chat list or bubbles — zero-refresh by construction).
    @State private var allowDraft = ""
    @State private var blockDraft = ""
    @State private var allowError: String?
    @State private var blockError: String?
    /// Attention-surface refusal text (Settings-local, zero-refresh).
    @State private var windowError: String?
    @State private var schedError: String?
    /// Inline-translation target (e1-translation): same key the
    /// TranslationStore reads (default = system language).
    @AppStorage("om.translation.target") private var translationTarget = MessageTranslation.defaultTargetCode()
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's models (single source of truth).
    init(
        auth: AuthViewModel,
        catchUp: CatchUpStore = CatchUpStore(),
        notifs: MessageNotifications = MessageNotifications(),
        rules: RulesStore = RulesStore(),
        chats: ChatListViewModel,
        quiet: QuietHoursStore = QuietHoursStore(),
        focus: FocusSyncStore = FocusSyncStore(),
        sched: PresenceScheduleStore = PresenceScheduleStore(),
        blocked: BlockedStore = BlockedStore(defaults: nil),
        accounts: AccountStore = AccountStore(),
        call: CallStore = CallStore(),
        canned: CannedResponsesStore = CannedResponsesStore(),
        ghost: GhostStore = GhostStore(),
        density: DensityStore = DensityStore(),
        onAccountAdded: @escaping (AuthViewModel) -> Void = { _ in },
        onRemoveAccount: @escaping (String) -> Void = { _ in }
    ) {
        _auth = ObservedObject(wrappedValue: auth)
        _catchUp = ObservedObject(wrappedValue: catchUp)
        _notifs = ObservedObject(wrappedValue: notifs)
        _rules = ObservedObject(wrappedValue: rules)
        _chats = ObservedObject(wrappedValue: chats)
        _quiet = ObservedObject(wrappedValue: quiet)
        _focus = ObservedObject(wrappedValue: focus)
        _sched = ObservedObject(wrappedValue: sched)
        _blocked = ObservedObject(wrappedValue: blocked)
        _accounts = ObservedObject(wrappedValue: accounts)
        _call = ObservedObject(wrappedValue: call)
        _canned = ObservedObject(wrappedValue: canned)
        _ghost = ObservedObject(wrappedValue: ghost)
        _density = ObservedObject(wrappedValue: density)
        self.onAccountAdded = onAccountAdded
        self.onRemoveAccount = onRemoveAccount
        fixedAccount = nil
    }

    /// Fixed view (previews, shots, demo): never touches core.
    @MainActor
    init(account: AccountInfo) {
        _auth = ObservedObject(wrappedValue: .demo(.signedOut))
        _catchUp = ObservedObject(wrappedValue: CatchUpStore())
        _notifs = ObservedObject(wrappedValue: MessageNotifications())
        _rules = ObservedObject(wrappedValue: RulesStore())
        _chats = ObservedObject(wrappedValue: ChatListViewModel())
        if Self.isAttentionShot {
            // e2-attention shot: read the throwaway suite AppState
            // seeded (never the real defaults), offline reader.
            let suite = UserDefaults(suiteName: "shot-attention") ?? .standard
            _quiet = ObservedObject(wrappedValue: QuietHoursStore(defaults: suite))
            _focus = ObservedObject(wrappedValue: FocusSyncStore(defaults: suite, reader: { false }))
            _sched = ObservedObject(wrappedValue: PresenceScheduleStore(defaults: suite))
        } else {
            _quiet = ObservedObject(wrappedValue: QuietHoursStore())
            _focus = ObservedObject(wrappedValue: FocusSyncStore())
            _sched = ObservedObject(wrappedValue: PresenceScheduleStore())
        }
        _blocked = ObservedObject(wrappedValue: BlockedStore(defaults: nil))
        _accounts = ObservedObject(wrappedValue: AccountStore())
        // Demo slot: taps flip local state only, never touch core.
        _call = ObservedObject(wrappedValue: CallStore(demo: true))
        if Self.isChatsShot || Self.isComposerShot {
            // Chats/composer shot: throwaway suite + two demo rows
            // (never the real templates), wiped first for determinism.
            let suite = UserDefaults(suiteName: "shot-chats") ?? .standard
            suite.removePersistentDomain(forName: "shot-chats")
            let seeded = CannedResponsesStore(defaults: suite)
            _ = seeded.add(title: "Standup", body: "Yesterday: <done>. Today: <plan>. Blockers: none.")
            _ = seeded.add(title: "OOO", body: "Out today, back tomorrow — ping Megan for anything urgent.")
            _canned = ObservedObject(wrappedValue: seeded)
        } else {
            _canned = ObservedObject(wrappedValue: CannedResponsesStore())
        }
        _ghost = ObservedObject(wrappedValue: GhostStore())
        if Self.isChatsShot {
            // Chats shot: throwaway suite (never the real defaults),
            // deterministic Comfortable.
            let suite = UserDefaults(suiteName: "shot-chats") ?? .standard
            _density = ObservedObject(wrappedValue: DensityStore(defaults: suite))
        } else {
            _density = ObservedObject(wrappedValue: DensityStore())
        }
        onAccountAdded = { _ in }
        onRemoveAccount = { _ in }
        fixedAccount = account
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.title, systemImage: category.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollViewReader { proxy in
                ScrollView {
                    Form {
                        detailSections
                    }
                    .formStyle(.grouped)
                    .padding()
                }
                .navigationTitle(selection.title)
                .task {
                    // Fixed (preview/shot/demo) view must not touch the
                    // real keychain.
                    // --shot-no-klipy also skips it (a prompting klipy item
                    // parks the main thread on SecurityAgent and freezes
                    // shot automation).
                    if fixedAccount == nil {
                        if !CommandLine.arguments.contains("--shot-no-klipy") {
                            klipyAPIKey = KlipyClient.storedKey()
                        }
                        await auth.refreshStatus()
                    }
                }
                .onAppear {
                    // Shot hook: --show-settings-keywords lands the
                    // Keyword alerts section at the top (no input path).
                    // (--show-settings-attention preselects Notifications
                    // instead — see SettingsRouting.initialCategory.)
                    if Self.isKeywordsShot {
                        proxy.scrollTo("shot-keywords", anchor: .top)
                    }
                }
            }
        }
        .frame(width: 660, height: Self.shotHeight)
    }

    /// Detail form for the selected sidebar category.
    @ViewBuilder
    private var detailSections: some View {
        switch selection {
        case .account: accountSections
        case .notifications: notificationSections
        case .chats: chatSections
        case .calls: callSections
        case .summaries: CatchUpSettingsSection(catchUp: catchUp)
        case .gifs: gifSections
        case .advanced: advancedSections
        }
    }

    @ViewBuilder
    private var accountSections: some View {
        Section("Account") {
            LabeledContent("Status", value: account.detail)
                .textSelection(.enabled)
        }
        if fixedAccount == nil {
            Section("Accounts") {
                if accounts.accounts.isEmpty {
                    Text("No accounts yet — sign in below to add the first.")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                } else {
                    ForEach(accounts.accounts) { record in
                        SettingsAccountRow(
                            record: record,
                            vm: accounts.vm(for: record.id),
                            isActive: record.id == accounts.activeID,
                            onRemove: { removeCandidate = record })
                    }
                    Button("Add Account…") {
                        pendingAddVM = accounts.beginAdd()
                        showAddAccount = true
                    }
                }
            }
            .sheet(isPresented: $showAddAccount) {
                if let vm = pendingAddVM {
                    AddAccountSheet(vm: vm, onAdded: onAccountAdded)
                }
            }
            .confirmationDialog(
                "Remove this account?",
                isPresented: Binding(
                    get: { removeCandidate != nil },
                    set: { if !$0 { removeCandidate = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove Account", role: .destructive) {
                    if let id = removeCandidate?.id {
                        onRemoveAccount(id)
                    }
                    removeCandidate = nil
                }
                Button("Cancel", role: .cancel) { removeCandidate = nil }
            } message: {
                Text("Its sign-in and per-account caches are deleted from this Mac. Other accounts are unaffected.")
            }
            Section("Sign in") {
                AuthView(model: auth, embedded: true)
            }
        }
    }

    @ViewBuilder
    private var notificationSections: some View {
        Section("Notifications") {
            Toggle("Message banners", isOn: $notifs.enabled)
                .help("When off, no chat banners are posted")
            Toggle("Show message preview", isOn: $notifs.showPreview)
                .help("When off, banners show who wrote, never the text")
            Toggle("Play banner sound", isOn: $notifs.sound)
                .help("When off, banners post silent")
            LabeledContent("System permission", value: permissionText)
        }
        Section("Keyword alerts") {
            EmptyView().id("shot-keywords")
            keywordGroup(
                title: "Always notify",
                words: rules.config.allowKeywords,
                draft: $allowDraft,
                error: allowError,
                placeholder: "Add word, e.g. outage",
                emptyText: "No always-notify words yet.",
                remove: rules.removeAllowKeyword,
                add: submitAllow)
            keywordGroup(
                title: "Never notify",
                words: rules.config.blockKeywords,
                draft: $blockDraft,
                error: blockError,
                placeholder: "Add word, e.g. lunch",
                emptyText: "No never-notify words yet.",
                remove: rules.removeBlockKeyword,
                add: submitBlock)
            Text("Always words banner even in noisy or mentions-only chats (subtitle “Keyword alert”); never words silence. Case-insensitive whole words; re: prefix is a regex. Never wins over always; muted chats, DND, and quiet hours still hold everything.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        Section("Quiet hours") {
            ForEach(quiet.windows.indices, id: \.self) { index in
                QuietWindowFields(
                    title: "Window \(index + 1)",
                    window: windowBinding(index),
                    onRemove: index == 0 ? nil : { quiet.removeWindow(at: index) })
            }
            HStack {
                Button("Add window") {
                    if !quiet.addWindow() {
                        windowError = "Maximum \(QuietHoursStore.maxWindows) windows."
                    } else {
                        windowError = nil
                    }
                }
                .disabled(quiet.windows.count >= QuietHoursStore.maxWindows)
                if let windowError {
                    Text(windowError)
                        .font(DietType.caption1)
                        .foregroundStyle(Color(nsColor: DietColor.danger))
                }
            }
            Text("Banners and sounds pause while ANY window matches (overnight ranges like 22:00–07:00 wrap past midnight), mentions included. Unread pauses too while quiet — the Mentions row still tracks threads for review; suppressions are counted in Diagnostics.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        Section("Do Not Disturb") {
            Toggle("Do Not Disturb", isOn: dndBinding)
                .help("Silence banners and sounds now, until the auto-expiry below")
            Picker("Auto-expire", selection: $quiet.pendingDNDOption) {
                ForEach(DNDDuration.allCases, id: \.self) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .onChange(of: quiet.pendingDNDOption) { _, next in
                // Re-clock a live DND when the choice changes.
                if quiet.dndOn { quiet.enableDND(next) }
            }
            LabeledContent("Status", value: quiet.dndStatus())
            Text("Manual silence with auto-expiry. Like the schedule, it holds banners and sounds — unread pauses too while on.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        Section("Ghost mode") {
            Toggle("Ghost mode", isOn: $ghost.master)
                .help("Withhold your outbound read and presence signals")
            Toggle("Hide read receipts", isOn: $ghost.suppressReceipts)
                .help("Viewing chats sends no read positions to the server")
                .disabled(!ghost.master)
            Toggle("Freeze my presence", isOn: $ghost.suppressPresence)
                .help("Hold your status and presence writes while ghosted")
                .disabled(!ghost.master)
            Text("While on, reading chats sends NO read receipts and your Teams status is frozen (picker and scheduled changes are held, never sent). Incoming receipts and presence still show; your local unread badges still clear on open. Covers this Mac only — phone and web still mark read.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        Section("Focus sync") {
            Toggle("Quiet while a macOS Focus is active", isOn: $focus.syncEnabled)
                .help("On for new installs — system Focus quiets the app like scheduled quiet hours")
            LabeledContent("System Focus", value: focusStatusText)
            Text("When on, an active Focus mode holds banners and sounds exactly like quiet hours (mentions included; unread pauses; suppressions counted in Diagnostics). On by default; turn off to always buzz. When the system state is unreadable the app stays loud — never stuck silent — and Diagnostics names the probe error.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        Section("Presence schedules") {
            Toggle("Set my status on a schedule", isOn: $sched.enabled)
                .help("Switch your Teams status automatically per window below")
            ForEach(sched.entries) { entry in
                Group {
                    Picker("Status", selection: entryStatusBinding(entry.id)) {
                        ForEach(PresenceStatus.allCases, id: \.rawValue) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    QuietWindowFields(
                        title: "Window",
                        window: entryWindowBinding(entry.id),
                        onRemove: { sched.removeEntry(id: entry.id) })
                }
            }
            .disabled(!sched.enabled)
            HStack {
                Button("Add schedule") {
                    if !sched.addEntry(PresenceScheduleEntry()) {
                        schedError = "Maximum \(PresenceScheduleStore.maxEntries) schedules."
                    } else {
                        schedError = nil
                    }
                }
                .disabled(!sched.enabled || sched.entries.count >= PresenceScheduleStore.maxEntries)
                if let schedError {
                    Text(schedError)
                        .font(DietType.caption1)
                        .foregroundStyle(Color(nsColor: DietColor.danger))
                }
            }
            Text("While a window is active your Teams status switches to its target (first match wins). Picking a status yourself pauses the schedule until the next window starts. Failures keep your last status — see Diagnostics.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }

    @ViewBuilder
    private var chatSections: some View {
        Section("Per-chat overrides") {
            if chats.chats.isEmpty, rules.config.mutedChatIDs.isEmpty, rules.config.mentionOnlyChatIDs.isEmpty {
                Text("No chats loaded yet. Overridden chats appear here once the chat list loads.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            } else {
                ForEach(chats.chats) { chat in
                    Picker(chat.name, selection: levelBinding(chat.id)) {
                        ForEach(ChatNotifyLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .help(levelHelp(chatID: chat.id))
                }
                ForEach(orphanedOverrideIDs, id: \.self) { chatID in
                    HStack {
                        Text(chatID)
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reset") {
                            rules.setLevel(chatID: chatID, level: .all)
                        }
                    }
                    .help("Overridden, but no longer in the chat list")
                }
            }
            Text("Muted chats never banner and never accrue unread (rules reason “chat-muted”); mentions-only chats banner on mention alone.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        Section("Blocked users") {
            if blocked.users.isEmpty {
                Text("No blocked users. Block someone from a 1:1 chat in the sidebar (right-click).")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            } else {
                ForEach(blocked.sortedUsers) { user in
                    HStack {
                        Text(user.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Unblock") {
                            blocked.unblock(chatID: user.chatID)
                        }
                    }
                    .help("Unblock \(user.displayName)")
                }
            }
            Text("Blocked users never banner and never accrue unread. Unblocked chats reappear when the list next loads.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        Section("Translation") {
            if MessageTranslation.isAvailable {
                Picker("Translate to", selection: $translationTarget) {
                    ForEach(translationOptions, id: \.self) { code in
                        Text(MessageTranslation.displayName(for: code)).tag(code)
                    }
                }
                Text("Per-bubble Translate renders below the original. On-device only — nothing is sent anywhere; works offline once models download.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            } else {
                Text(MessageTranslation.unavailableReason)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
        }
        Section("Appearance") {
            Picker("Density", selection: $density.mode) {
                ForEach(MessageDensity.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Message spacing: Comfortable (roomy) or Compact (more fits on screen)")
            Text("Compact tightens message and chat-row spacing so more fits on screen. Text size never changes.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        TemplatesSettingsSection(canned: canned)
        QuickComposerSettingsSection()
    }

    @ViewBuilder
    private var callSections: some View {
        Section("Calls") {
            let tc = TestCallSettings.describe(
                signedIn: account.signedIn,
                busy: call.busy,
                call: call.call)
            HStack {
                Button(tc.placeLabel) { call.echoLive() }
                    .disabled(!tc.placeEnabled)
                    .help("Place an echo-bot test call with live audio (mic + speaker check)")
                if tc.showEnd {
                    Button("End test call") { call.end() }
                        .disabled(!tc.endEnabled)
                }
            }
            LabeledContent("Status", value: tc.status)
            if let err = call.error {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .textSelection(.enabled)
            }
            Text("The test call dials the Teams echo bot only — speak and you hear your own audio back. Never dials a person.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }

    @ViewBuilder
    private var gifSections: some View {
        Section("GIFs (KLIPY)") {
            SecureField("KLIPY API key", text: $klipyAPIKey)
                .onChange(of: klipyAPIKey) { _, next in
                    KlipyClient.saveKey(next)
                }
            Text("Bring your own free key (klipy.com → Developers; stored in your keychain). Empty = GIF picker stays off; nothing is sent anywhere.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }

    @ViewBuilder
    private var advancedSections: some View {
        Section("Diagnostics") {
            Button("Open Diagnostics Window") {
                openWindow(id: AppIdentity.diagWindowID)
            }
            .help("Token health, feed counters, and call session numbers live there")
            Text("Token health, feed counters, and call session numbers live in the Diagnostics window (Window ▸ Diagnostics).")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }

    /// Translation picker options: curated list, current choice kept
    /// first when off-list (never strand the selection).
    private var translationOptions: [String] {
        MessageTranslation.targetCodes.contains(translationTarget)
            ? MessageTranslation.targetCodes
            : [translationTarget] + MessageTranslation.targetCodes
    }

    /// Overridden ids with no roster row (renamed/left chats): still
    /// enforced, listed so they can be reset. Sorted for stability.
    private var orphanedOverrideIDs: [String] {
        let known = Set(chats.chats.map(\.id))
        let overridden = rules.config.mutedChatIDs.union(rules.config.mentionOnlyChatIDs)
        return overridden.filter { !known.contains($0) }.sorted()
    }

    private func levelBinding(_ chatID: String) -> Binding<ChatNotifyLevel> {
        Binding(
            get: { rules.level(chatID: chatID) },
            set: { rules.setLevel(chatID: chatID, level: $0) })
    }

    private func levelHelp(chatID: String) -> String {
        switch rules.level(chatID: chatID) {
        case .all: "All: every message banners. Pick Mentions only or Muted to quiet this chat."
        case .mentions: "Mentions only: banners on mention alone. Pick All to restore, Muted to silence."
        case .muted: "Muted: no banners, no unread. Pick All or Mentions only to restore."
        }
    }

    /// One keyword word-list editor (always/never): rows with Remove,
    /// TextField + Add, refusal text. Native controls only.
    private func keywordGroup(
        title: String,
        words: [String],
        draft: Binding<String>,
        error: String?,
        placeholder: String,
        emptyText: String,
        remove: @escaping (String) -> Void,
        add: @escaping () -> Void
    ) -> some View {
        Group {
            Text(title).font(DietType.headline)
            if words.isEmpty {
                Text(emptyText)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            } else {
                ForEach(words, id: \.self) { word in
                    HStack {
                        Text(word)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Remove") { remove(word) }
                    }
                }
            }
            HStack {
                TextField(placeholder, text: draft)
                    .onSubmit(add)
                Button("Add", action: add)
            }
            if let error {
                Text(error)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
            }
        }
    }

    /// Submit the always draft: refusal text shows, success clears.
    private func submitAllow() {
        allowError = rules.addAllowKeyword(allowDraft)
        if allowError == nil { allowDraft = "" }
    }

    /// Submit the never draft: refusal text shows, success clears.
    private func submitBlock() {
        blockError = rules.addBlockKeyword(blockDraft)
        if blockError == nil { blockDraft = "" }
    }

    /// Shot hook flag (R6): fixed sanitized view, scrolled to keywords.
    fileprivate static var isKeywordsShot: Bool {
        CommandLine.arguments.contains("--show-settings-keywords")
    }

    /// Shot hook flag (e2-attention): fixed seeded view preselected
    /// on Notifications (the Attention surface: Quiet hours + Focus +
    /// schedules, seeded from the throwaway suite).
    fileprivate static var isAttentionShot: Bool {
        CommandLine.arguments.contains("--show-settings-attention")
    }

    /// Shot hook flag (r8-merge): fixed view preselected on Chats
    /// (Templates section in situ, seeded throwaway rows).
    fileprivate static var isChatsShot: Bool {
        CommandLine.arguments.contains("--show-settings-chats")
    }

    /// Shot hook flag (f1-composer): fixed view preselected on Chats
    /// with the full detail (through Quick Composer) fitting without
    /// scrolling (Form-embedded scrollTo is broken — height only).
    fileprivate static var isComposerShot: Bool {
        CommandLine.arguments.contains("--show-settings-composer")
    }

    /// Shot window heights: the full Attention surface (banners
    /// through schedules) and the Chats detail (through Templates,
    /// or through Quick Composer for the composer shot) fit without
    /// scrolling; real launches stay 520.
    private static var shotHeight: CGFloat {
        if isAttentionShot { return 2150 }
        if isComposerShot { return 1250 }
        if isChatsShot { return 950 }
        return 520
    }

    private var account: AccountInfo {
        if let fixedAccount { return fixedAccount }
        return AccountInfo.from(authState: auth.state, status: auth.status)
    }

    /// Read-only system grant state (requested once at live launch).
    private var permissionText: String {
        switch notifs.authorized {
        case .some(true): "Allowed"
        case .some(false): "Denied"
        case .none: "Unknown"
        }
    }

    // MARK: quiet hours bridges (minutes <-> DatePicker dates, day set)

    /// Enabling applies the pending auto-expiry; disabling clears it.
    private var dndBinding: Binding<Bool> {
        Binding(
            get: { quiet.dndOn },
            set: { $0 ? quiet.enableDND(quiet.pendingDNDOption) : quiet.disableDND() })
    }

    /// Element binding for quiet window `index` (bounds-safe: reads a
    /// default out of range, drops out-of-range writes).
    private func windowBinding(_ index: Int) -> Binding<QuietHoursWindow> {
        Binding(
            get: { quiet.windows.indices.contains(index) ? quiet.windows[index] : QuietHoursWindow() },
            set: {
                guard quiet.windows.indices.contains(index) else { return }
                quiet.windows[index] = $0
            })
    }

    /// Status binding for schedule entry `id` (unknown ids read Busy,
    /// writes drop).
    private func entryStatusBinding(_ id: UUID) -> Binding<PresenceStatus> {
        Binding(
            get: { sched.entries.first(where: { $0.id == id })?.status ?? .busy },
            set: { next in
                guard let i = sched.entries.firstIndex(where: { $0.id == id }) else { return }
                sched.entries[i].status = next
            })
    }

    /// Window binding for schedule entry `id` (unknown ids read a
    /// default window, writes drop).
    private func entryWindowBinding(_ id: UUID) -> Binding<QuietHoursWindow> {
        Binding(
            get: { sched.entries.first(where: { $0.id == id })?.window ?? QuietHoursWindow() },
            set: { next in
                guard let i = sched.entries.firstIndex(where: { $0.id == id }) else { return }
                sched.entries[i].window = next
            })
    }

    /// Focus sync status line (sync state + live reading + probe error).
    /// gap-g5: the probe error shows even with sync off — a broken
    /// probe is never hidden behind the toggle.
    private var focusStatusText: String {
        if let error = focus.error { return "unreadable (\(error))" }
        if !focus.syncEnabled { return "off" }
        return focus.focusActive ? "active — quiet" : "inactive"
    }
}

/// One schedule-window editor (e2-attention): shared by the Quiet
/// hours window list and the presence-schedule editor. Native controls
/// only (Toggle, DatePicker, checkboxes, Button).
struct QuietWindowFields: View {
    let title: String
    @Binding var window: QuietHoursWindow
    /// Nil for pinned window #1 (cleared, never dropped — no button).
    let onRemove: (() -> Void)?

    var body: some View {
        Group {
            HStack {
                Toggle(title, isOn: $window.enabled)
                    .help("Enable this window")
                Spacer()
                if let onRemove {
                    Button("Remove", action: onRemove)
                }
            }
            DatePicker(
                "Start",
                selection: startBinding,
                displayedComponents: .hourAndMinute)
                .disabled(!window.enabled)
            DatePicker(
                "End",
                selection: endBinding,
                displayedComponents: .hourAndMinute)
                .disabled(!window.enabled)
            LabeledContent("Days") {
                HStack {
                    ForEach(1 ... 7, id: \.self) { day in
                        Toggle(
                            Self.dayLetter(day),
                            isOn: dayBinding(day))
                            .toggleStyle(.checkbox)
                            .help(Self.dayName(day))
                    }
                }
            }
            .disabled(!window.enabled)
        }
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { QuietHoursStore.timeOfDay(minutes: window.startMinutes) },
            set: { window.startMinutes = QuietHoursStore.minutes(ofTime: $0) })
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { QuietHoursStore.timeOfDay(minutes: window.endMinutes) },
            set: { window.endMinutes = QuietHoursStore.minutes(ofTime: $0) })
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { window.days.contains(day) },
            set: {
                if $0, !window.days.contains(day) {
                    window.days.append(day)
                } else if !$0 {
                    window.days.removeAll(where: { $0 == day })
                }
            })
    }

    /// Single-letter checkbox label (Sunday-first, Calendar order).
    private static func dayLetter(_ day: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return symbols[(day - 1 + symbols.count) % symbols.count]
    }

    /// Full day name (checkbox tooltip).
    private static func dayName(_ day: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols[(day - 1 + symbols.count) % symbols.count]
    }
}

/// One Settings Accounts row: state dot + name + per-account status +
/// active marker + remove. Observes the account's VM when present.
struct SettingsAccountRow: View {
    let record: AccountRecord
    let vm: AuthViewModel?
    let isActive: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let vm {
                ObservedAccountDot(vm: vm)
            } else {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(record.displayName).lineLimit(1)
                    if isActive {
                        Text("Active")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                }
                if let upn = record.upn, !upn.isEmpty {
                    Text(upn)
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(1)
                }
                if let vm {
                    ObservedAccountStatus(vm: vm)
                }
            }
            Spacer()
            Button("Remove", role: .destructive, action: onRemove)
        }
        .accessibilityLabel("\(record.displayName)\(isActive ? ", active" : "")")
    }
}

private struct ObservedAccountDot: View {
    @ObservedObject var vm: AuthViewModel

    var body: some View {
        Circle()
            .fill(AccountStateDot.color(for: vm.state))
            .frame(width: 8, height: 8)
    }
}

private struct ObservedAccountStatus: View {
    @ObservedObject var vm: AuthViewModel

    var body: some View {
        Text(AccountStateDot.label(for: vm.state))
            .font(DietType.caption1)
            .foregroundStyle(DietColor.textSecondaryColor)
            .lineLimit(1)
    }
}

/// Templates Settings section (e2-canned): rows with Up/Down/Edit/
/// Remove, create fields with inline refusal text. Extracted
/// (CatchUpSettingsSection precedent) so the shot hook renders the
/// real section standalone.
struct TemplatesSettingsSection: View {
    @ObservedObject var canned: CannedResponsesStore
    @State private var titleDraft = ""
    @State private var bodyDraft = ""
    @State private var error: String?
    @State private var editingTemplate: CannedTemplate?

    var body: some View {
        Section("Templates") {
            if canned.templates.isEmpty {
                Text("No templates yet. Add one below — the composer button inserts it into your draft.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            } else {
                ForEach(Array(canned.templates.enumerated()), id: \.element.id) { i, template in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(template.body)
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Up") { canned.move(from: i, to: i - 1) }
                            .disabled(i == 0)
                        Button("Down") { canned.move(from: i, to: i + 1) }
                            .disabled(i == canned.templates.count - 1)
                        Button("Edit") { editingTemplate = template }
                        Button("Remove") { canned.delete(id: template.id) }
                    }
                }
            }
            TextField("Title, e.g. Standup", text: $titleDraft)
            TextField("Message text", text: $bodyDraft, axis: .vertical)
                .lineLimit(2...4)
            HStack {
                Button("Add template") {
                    error = canned.add(title: titleDraft, body: bodyDraft)
                    if error == nil {
                        titleDraft = ""
                        bodyDraft = ""
                    }
                }
                Spacer()
            }
            if let error {
                Text(error)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
            }
            Text("Templates insert into the composer draft — nothing sends until you hit Send. Stored on this Mac only.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditSheet(canned: canned, template: template)
        }
    }
}

/// Standalone shot view (--show-settings-templates): the real
/// Templates section in a compact window (Form-embedded scrollTo is
/// broken for every section, keywords included — no scroll hook can
/// land it in the full Settings window).
struct TemplatesShotView: View {
    @ObservedObject var canned: CannedResponsesStore

    var body: some View {
        Form {
            TemplatesSettingsSection(canned: canned)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
    }
}

/// Edit sheet for one template (e2-canned): native fields + Save with
/// inline refusal text. Dismisses on save.
private struct TemplateEditSheet: View {
    @ObservedObject var canned: CannedResponsesStore
    let template: CannedTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var draftBody: String
    @State private var error: String?

    init(canned: CannedResponsesStore, template: CannedTemplate) {
        self.canned = canned
        self.template = template
        _title = State(initialValue: template.title)
        _draftBody = State(initialValue: template.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            Text("Edit template")
                .font(DietType.headline)
            TextField("Title", text: $title)
            TextField("Message text", text: $draftBody, axis: .vertical)
                .lineLimit(2...6)
            if let error {
                Text(error)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    error = canned.update(id: template.id, title: title, body: draftBody)
                    if error == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DietSpace.md)
        .frame(width: 380)
    }
}
