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
    @AppStorage("tenorAPIKey") private var tenorAPIKey = ""
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's models (single source of truth).
    init(
        auth: AuthViewModel,
        catchUp: CatchUpStore = CatchUpStore(),
        notifs: MessageNotifications = MessageNotifications()
    ) {
        _auth = ObservedObject(wrappedValue: auth)
        _catchUp = ObservedObject(wrappedValue: catchUp)
        _notifs = ObservedObject(wrappedValue: notifs)
        fixedAccount = nil
    }

    /// Fixed view (previews, shots): never touches core.
    @MainActor
    init(account: AccountInfo) {
        _auth = ObservedObject(wrappedValue: .demo(.signedOut))
        _catchUp = ObservedObject(wrappedValue: CatchUpStore())
        _notifs = ObservedObject(wrappedValue: MessageNotifications())
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
}
