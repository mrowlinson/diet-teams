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
                    Toggle("Quiet hours", isOn: $quiet.hours.enabled)
                        .help("When on, no banners or sounds post inside the window — mentions included")
                    DatePicker(
                        "Starts", selection: startBinding,
                        displayedComponents: .hourAndMinute)
                        .disabled(!quiet.hours.enabled)
                    DatePicker(
                        "Ends", selection: endBinding,
                        displayedComponents: .hourAndMinute)
                        .disabled(!quiet.hours.enabled)
                    Text("Quiet hours silence every banner and sound, including @me/@team mentions (which otherwise break through mute). The Mentions row still tracks threads for review; DND follows your Teams presence instead.")
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

    /// Quiet window edges as wall-clock pickers (stored as minutes).
    private var startBinding: Binding<Date> {
        Binding(
            get: { QuietHours.date(forMinutes: quiet.hours.startMinutes) },
            set: { quiet.hours.startMinutes = QuietHours.minutesOfDay($0) })
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { QuietHours.date(forMinutes: quiet.hours.endMinutes) },
            set: { quiet.hours.endMinutes = QuietHours.minutesOfDay($0) })
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
}
