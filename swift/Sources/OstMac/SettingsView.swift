// SettingsView.swift — om-settings-trim lane: essentials only, native Form.
//
// Kept (every row wired to real behavior): Account status (gate
// one-liner), Sign in (shared AuthViewModel), Notifications (banner,
// preview and sound toggles, persisted), Per-chat overrides (mute
// toggles per chat, persisted in rules.json and enforced by the
// rules engine), GIFs Tenor key (picker reads the same key),
// Thread catch-up (CatchUpStore; Base URL hides when the CLI provider
// ignores it).
// Removed: Application (dup of About), Diagnostics (moved to the
// Diagnostics window — Window ▸ Diagnostics).
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
    @AppStorage("tenorAPIKey") private var tenorAPIKey = ""
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's models (single source of truth).
    init(
        auth: AuthViewModel,
        catchUp: CatchUpStore = CatchUpStore(),
        notifs: MessageNotifications = MessageNotifications(),
        rules: RulesStore = RulesStore(),
        chats: ChatListViewModel,
        quiet: QuietHoursStore = QuietHoursStore(),
        blocked: BlockedStore = BlockedStore(defaults: nil)
    ) {
        _auth = ObservedObject(wrappedValue: auth)
        _catchUp = ObservedObject(wrappedValue: catchUp)
        _notifs = ObservedObject(wrappedValue: notifs)
        _rules = ObservedObject(wrappedValue: rules)
        _chats = ObservedObject(wrappedValue: chats)
        _quiet = ObservedObject(wrappedValue: quiet)
        _blocked = ObservedObject(wrappedValue: blocked)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(chats.chats) { chat in
                            Toggle(chat.name, isOn: muteBinding(chat.id))
                                .help(muteHelp(chatID: chat.id))
                        }
                        ForEach(orphanedMuteIDs, id: \.self) { chatID in
                            HStack {
                                Text(chatID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Blocked users") {
                    if blocked.users.isEmpty {
                        Text("No blocked users. Block someone from a 1:1 chat in the sidebar (right-click).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("GIFs (Tenor)") {
                    SecureField("Tenor API key", text: $tenorAPIKey)
                    Text("Bring your own free key (Google Cloud Console → Tenor API). Empty = GIF picker stays off; nothing is sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                CatchUpSettingsSection(catchUp: catchUp)
            }
            .formStyle(.grouped)
            .padding()
        }
        // Live embeds the full AuthView (min 420 tall); fixed stays compact.
        .frame(width: 460, height: fixedAccount == nil ? 760 : nil)
        .task {
            guard fixedAccount == nil else { return }
            await auth.refreshStatus()
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
