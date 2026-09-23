// SettingsView.swift — om-auth-gate lane: Settings wired to the shared
// AuthViewModel (was: read-only row from a direct core status read).
// Account section shows the 11-state gate one-liner; the Sign in section
// embeds the full AuthView (code/copy/browser, polling, refresh, sign-out).
// Diagnostics (om-steal-ids) shows token health + live probe results.
//
// om-reskin-chrome: Diet cards on window bg (was: grouped Form).
import DietDesign
import OstMacCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var auth: AuthViewModel
    @StateObject private var health: HealthStore
    @AppStorage("tenorAPIKey") private var tenorAPIKey = ""
    @ObservedObject private var catchUp: CatchUpStore
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's AuthViewModel (single source of truth).
    init(auth: AuthViewModel, catchUp: CatchUpStore = CatchUpStore()) {
        _auth = ObservedObject(wrappedValue: auth)
        _health = StateObject(wrappedValue: HealthStore())
        _catchUp = ObservedObject(wrappedValue: catchUp)
        fixedAccount = nil
    }

    /// Fixed view (previews, shots): never touches core.
    @MainActor
    init(account: AccountInfo) {
        _auth = ObservedObject(wrappedValue: .demo(.signedOut))
        let demoHealth = HealthStore()
        demoHealth.adopt(HealthStore.demo)
        _health = StateObject(wrappedValue: demoHealth)
        _catchUp = ObservedObject(wrappedValue: CatchUpStore())
        fixedAccount = account
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: DietSpace.section) {
                DietSectionCard("Account", systemImage: "person.crop.circle") {
                    HStack {
                        Text("Status")
                            .font(DietType.body)
                            .foregroundStyle(DietColor.textSecondaryColor)
                        Spacer()
                        Text(account.detail)
                            .font(DietType.body)
                            .foregroundStyle(
                                account.signedIn
                                    ? DietColor.textPrimaryColor
                                    : DietColor.textSecondaryColor)
                            .textSelection(.enabled)
                    }
                }
                if fixedAccount == nil {
                    DietSectionCard("Sign in", systemImage: "key") {
                        AuthView(model: auth)
                    }
                }
                DietSectionCard("Diagnostics", systemImage: "stethoscope") {
                    HealthView(store: health)
                }
                DietSectionCard("GIFs (Tenor)", systemImage: "photo") {
                    VStack(alignment: .leading, spacing: DietSpace.sm) {
                        DietSecureRow("Tenor API key", text: $tenorAPIKey)
                        Text("Bring your own free key (Google Cloud Console → Tenor API). Empty = GIF picker stays off; nothing is sent anywhere.")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                }
                DietSectionCard("Thread catch-up", systemImage: "sparkles") {
                    CatchUpSettingsSection(catchUp: catchUp)
                }
                DietSectionCard("Application", systemImage: "app.badge") {
                    VStack(spacing: DietSpace.xs) {
                        HStack {
                            Text("Version")
                                .font(DietType.body)
                                .foregroundStyle(DietColor.textSecondaryColor)
                            Spacer()
                            Text(AppIdentity.version)
                                .font(DietType.body)
                                .foregroundStyle(DietColor.textPrimaryColor)
                        }
                        HStack {
                            Text("Bundle ID")
                                .font(DietType.body)
                                .foregroundStyle(DietColor.textSecondaryColor)
                            Spacer()
                            Text(AppIdentity.bundleID)
                                .font(DietType.captionMono)
                                .foregroundStyle(DietColor.textPrimaryColor)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(DietSpace.md)
        }
        .background(DietColor.windowColor)
        // Live embeds the full AuthView (min 420 tall); fixed stays compact.
        .frame(width: 460, height: fixedAccount == nil ? 720 : nil)
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

/// Secure field in Diet well chrome (focus ring via accent outline).
private struct DietSecureRow: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    var body: some View {
        SecureField(prompt, text: $text)
            .textFieldStyle(.plain)
            .textContentType(.password)
            .font(DietType.body)
            .foregroundStyle(DietColor.textPrimaryColor)
            .focused($focused)
            .padding(.horizontal, DietSpace.sm)
            .frame(minHeight: DietSize.controlHeight)
            .background(DietColor.wellColor)
            .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .stroke(
                        focused ? Color.accentColor : DietColor.dividerColor,
                        lineWidth: focused ? 2 : 1)
            )
    }
}
