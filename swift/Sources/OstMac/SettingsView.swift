// SettingsView.swift — om-settings-trim lane: essentials only, native Form.
//
// Kept (every row wired to real behavior): Account status (gate
// one-liner), Sign in (shared AuthViewModel), Notifications (banner,
// preview and sound toggles, persisted), Per-chat overrides (mute
// toggles per chat, persisted in rules.json and enforced by the
// rules engine), GIFs KLIPY key (keychain; picker reads the same key),
// Thread catch-up (CatchUpStore; Base URL hides when the CLI provider
// ignores it).
// Removed: Application (dup of About), Diagnostics (moved to the
// Diagnostics window — Window ▸ Diagnostics).
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
    @ObservedObject private var blocked: BlockedStore
    @ObservedObject private var accounts: AccountStore
    private let onAccountAdded: (AuthViewModel) -> Void
    private let onRemoveAccount: (String) -> Void
    @State private var pendingAddVM: AuthViewModel?
    @State private var showAddAccount = false
    @State private var removeCandidate: AccountRecord?
    /// KLIPY BYO key, keychain-backed (never UserDefaults). Loaded on
    /// appear, saved on every edit (blank clears).
    @State private var klipyAPIKey = ""
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's models (single source of truth).
    init(
        auth: AuthViewModel,
        catchUp: CatchUpStore = CatchUpStore(),
        notifs: MessageNotifications = MessageNotifications(),
        rules: RulesStore = RulesStore(),
        chats: ChatListViewModel,
        quiet: QuietHoursStore = QuietHoursStore(),
        blocked: BlockedStore = BlockedStore(defaults: nil),
        accounts: AccountStore = AccountStore(),
        onAccountAdded: @escaping (AuthViewModel) -> Void = { _ in },
        onRemoveAccount: @escaping (String) -> Void = { _ in }
    ) {
        _auth = ObservedObject(wrappedValue: auth)
        _catchUp = ObservedObject(wrappedValue: catchUp)
        _notifs = ObservedObject(wrappedValue: notifs)
        _rules = ObservedObject(wrappedValue: rules)
        _chats = ObservedObject(wrappedValue: chats)
        _quiet = ObservedObject(wrappedValue: quiet)
        _blocked = ObservedObject(wrappedValue: blocked)
        _accounts = ObservedObject(wrappedValue: accounts)
        self.onAccountAdded = onAccountAdded
        self.onRemoveAccount = onRemoveAccount
        fixedAccount = nil
    }

    /// Fixed view (previews, shots): never touches core.
    @MainActor
    init(account: AccountInfo) {
        _auth = ObservedObject(wrappedValue: .demo(.signedOut))
        _catchUp = ObservedObject(wrappedValue: CatchUpStore())
        _notifs = ObservedObject(wrappedValue: MessageNotifications())
        _rules = ObservedObject(wrappedValue: RulesStore())
        _chats = ObservedObject(wrappedValue: ChatListViewModel())
        _quiet = ObservedObject(wrappedValue: QuietHoursStore())
        _blocked = ObservedObject(wrappedValue: BlockedStore(defaults: nil))
        _accounts = ObservedObject(wrappedValue: AccountStore())
        onAccountAdded = { _ in }
        onRemoveAccount = { _ in }
        fixedAccount = account
    }

    public var body: some View {
        ScrollView {
            Form {
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
                Section("Notifications") {
                    Toggle("Message banners", isOn: $notifs.enabled)
                        .help("When off, no chat banners are posted")
                    Toggle("Show message preview", isOn: $notifs.showPreview)
                        .help("When off, banners show who wrote, never the text")
                    Toggle("Play banner sound", isOn: $notifs.sound)
                        .help("When off, banners post silent")
                    LabeledContent("System permission", value: permissionText)
                }
                Section("Per-chat overrides") {
                    if chats.chats.isEmpty, rules.config.mutedChatIDs.isEmpty {
                        Text("No chats loaded yet. Muted chats appear here once the chat list loads.")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    } else {
                        ForEach(chats.chats) { chat in
                            Toggle(chat.name, isOn: muteBinding(chat.id))
                                .help(muteHelp(chatID: chat.id))
                        }
                        ForEach(orphanedMuteIDs, id: \.self) { chatID in
                            HStack {
                                Text(chatID)
                                    .font(DietType.caption1)
                                    .foregroundStyle(DietColor.textSecondaryColor)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Unmute") {
                                    rules.setMuted(chatID: chatID, muted: false)
                                }
                            }
                            .help("Muted, but no longer in the chat list")
                        }
                    }
                    Text("Muted chats never banner and never accrue unread (rules reason “chat-muted”).")
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
                Section("Quiet hours") {
                    Toggle("Scheduled quiet hours", isOn: $quiet.windowEnabled)
                        .help("Pause banners and sounds on a daily schedule")
                    DatePicker(
                        "Start",
                        selection: startBinding,
                        displayedComponents: .hourAndMinute)
                        .disabled(!quiet.windowEnabled)
                    DatePicker(
                        "End",
                        selection: endBinding,
                        displayedComponents: .hourAndMinute)
                        .disabled(!quiet.windowEnabled)
                    LabeledContent("Days") {
                        HStack {
                            ForEach(1 ... 7, id: \.self) { day in
                                Toggle(
                                    dayLetter(day),
                                    isOn: dayBinding(day))
                                    .toggleStyle(.checkbox)
                                    .help(dayName(day))
                            }
                        }
                    }
                    .disabled(!quiet.windowEnabled)
                    Text("Banners and sounds pause on schedule (overnight ranges like 22:00–07:00 wrap past midnight), mentions included. Unread pauses too while quiet — the Mentions row still tracks threads for review; suppressions are counted in Diagnostics.")
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
                Section("GIFs (KLIPY)") {
                    SecureField("KLIPY API key", text: $klipyAPIKey)
                        .onChange(of: klipyAPIKey) { _, next in
                            KlipyClient.saveKey(next)
                        }
                    Text("Bring your own free key (klipy.com → Developers; stored in your keychain). Empty = GIF picker stays off; nothing is sent anywhere.")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                CatchUpSettingsSection(catchUp: catchUp)
            }
            .formStyle(.grouped)
            .padding()
        }
        // Live embeds the full AuthView (min 420 tall); fixed stays compact.
        .frame(width: 460, height: fixedAccount == nil ? 760 : nil)
        .task {
            // Fixed (preview/shot) view must not touch the real keychain.
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
    }

    /// Muted ids with no roster row (renamed/left chats): still
    /// enforced, listed so they can be unmuted. Sorted for stability.
    private var orphanedMuteIDs: [String] {
        let known = Set(chats.chats.map(\.id))
        return rules.config.mutedChatIDs.filter { !known.contains($0) }.sorted()
    }

    private func muteBinding(_ chatID: String) -> Binding<Bool> {
        Binding(
            get: { rules.isMuted(chatID: chatID) },
            set: { rules.setMuted(chatID: chatID, muted: $0) })
    }

    private func muteHelp(chatID: String) -> String {
        rules.isMuted(chatID: chatID)
            ? "Muted: no banners, no unread. Flip off to unmute."
            : "Flip on to mute: no banners, no unread."
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

    private var startBinding: Binding<Date> {
        Binding(
            get: { QuietHoursStore.timeOfDay(minutes: quiet.startMinutes) },
            set: { quiet.startMinutes = QuietHoursStore.minutes(ofTime: $0) })
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { QuietHoursStore.timeOfDay(minutes: quiet.endMinutes) },
            set: { quiet.endMinutes = QuietHoursStore.minutes(ofTime: $0) })
    }

    /// Enabling applies the pending auto-expiry; disabling clears it.
    private var dndBinding: Binding<Bool> {
        Binding(
            get: { quiet.dndOn },
            set: { $0 ? quiet.enableDND(quiet.pendingDNDOption) : quiet.disableDND() })
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { quiet.days.contains(day) },
            set: {
                if $0, !quiet.days.contains(day) {
                    quiet.days.append(day)
                } else if !$0 {
                    quiet.days.removeAll(where: { $0 == day })
                }
            })
    }

    /// Single-letter checkbox label (Sunday-first, Calendar order).
    private func dayLetter(_ day: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return symbols[(day - 1 + symbols.count) % symbols.count]
    }

    /// Full day name (checkbox tooltip).
    private func dayName(_ day: Int) -> String {
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
