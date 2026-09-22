// SettingsView.swift — om-auth-gate lane: Settings wired to the shared
// AuthViewModel (was: read-only row from a direct core status read).
// Account section shows the 11-state gate one-liner; the Sign in section
// embeds the full AuthView (code/copy/browser, polling, refresh, sign-out).
// Diagnostics (om-steal-ids) shows token health + live probe results.
import OstMacCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var auth: AuthViewModel
    @StateObject private var health: HealthStore
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's AuthViewModel (single source of truth).
    init(auth: AuthViewModel) {
        _auth = ObservedObject(wrappedValue: auth)
        _health = StateObject(wrappedValue: HealthStore())
        fixedAccount = nil
    }

    /// Fixed view (previews, shots): never touches core.
    @MainActor
    init(account: AccountInfo) {
        _auth = ObservedObject(wrappedValue: .demo(.signedOut))
        let demoHealth = HealthStore()
        demoHealth.adopt(HealthStore.demo)
        _health = StateObject(wrappedValue: demoHealth)
        fixedAccount = account
    }

    public var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Status") {
                    Text(account.detail)
                        .foregroundStyle(account.signedIn ? .primary : .secondary)
                        .textSelection(.enabled)
                }
            }
            if fixedAccount == nil {
                Section("Sign in") {
                    AuthView(model: auth)
                }
            }
            Section("Diagnostics") {
                HealthView(store: health)
            }
            Section("Application") {
                LabeledContent("Version", value: AppIdentity.version)
                LabeledContent("Bundle ID", value: AppIdentity.bundleID)
            }
        }
        .formStyle(.grouped)
        // Live embeds the full AuthView (min 420 tall); fixed stays compact.
        .frame(width: 420, height: fixedAccount == nil ? CGFloat(1010) : nil)
        .task {
            guard fixedAccount == nil else { return }
            await auth.refreshStatus()
            health.runSoon()
        }
    }

    private var account: AccountInfo {
        if let fixedAccount { return fixedAccount }
        return AccountInfo.from(authState: auth.state, status: auth.status)
    }
}
