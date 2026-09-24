// SettingsView.swift — om-settings-trim lane: essentials only, native Form.
//
// Kept (every row wired to real behavior): Account status (gate
// one-liner), Sign in (shared AuthViewModel), Notifications (banner
// toggle, persisted), GIFs Tenor key (picker reads the same key),
// Thread catch-up (CatchUpStore; Base URL hides when the CLI provider
// ignores it).
// Removed: Application (dup of About), Diagnostics (moved to the
// Diagnostics window — Window ▸ Diagnostics).
import OstMacCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var auth: AuthViewModel
    @ObservedObject private var catchUp: CatchUpStore
    @ObservedObject private var notifs: MessageNotifications
    @ObservedObject private var quiet: QuietHoursStore
    @AppStorage("tenorAPIKey") private var tenorAPIKey = ""
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's models (single source of truth).
    init(
        auth: AuthViewModel,
        catchUp: CatchUpStore = CatchUpStore(),
        notifs: MessageNotifications = MessageNotifications(),
        quiet: QuietHoursStore = QuietHoursStore()
    ) {
        _auth = ObservedObject(wrappedValue: auth)
        _catchUp = ObservedObject(wrappedValue: catchUp)
        _notifs = ObservedObject(wrappedValue: notifs)
        _quiet = ObservedObject(wrappedValue: quiet)
        fixedAccount = nil
    }

    /// Fixed view (previews, shots): never touches core.
    @MainActor
    init(account: AccountInfo) {
        _auth = ObservedObject(wrappedValue: .demo(.signedOut))
        _catchUp = ObservedObject(wrappedValue: CatchUpStore())
        _notifs = ObservedObject(wrappedValue: MessageNotifications())
        _quiet = ObservedObject(wrappedValue: QuietHoursStore())
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
                        AuthView(model: auth)
                    }
                }
                Section("Notifications") {
                    Toggle("Message banners", isOn: $notifs.enabled)
                        .help("When off, no chat banners are posted")
                    LabeledContent("System permission", value: permissionText)
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
                    Text("Banners and sounds pause on schedule (overnight ranges like 22:00–07:00 wrap past midnight). Unread counts keep accruing; suppressed banners are counted in Diagnostics.")
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
                    Text("Manual silence with auto-expiry. Like the schedule, it holds banners and sounds only — unread counts keep accruing.")
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
        .frame(width: 460, height: fixedAccount == nil ? 720 : nil)
        .task {
            guard fixedAccount == nil else { return }
            await auth.refreshStatus()
        }
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
