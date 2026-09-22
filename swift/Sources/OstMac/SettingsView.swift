// SettingsView.swift — om-package lane: Settings window shell.
// Account row is read-only for now (status line from core); sign-in
// controls arrive in a later lane.
import OstMacCore
import SwiftUI

struct SettingsView: View {
    @State private var account: AccountInfo
    private let fixed: Bool

    /// Live view: loads account status from core on appear.
    init() {
        _account = State(initialValue: .loading)
        fixed = false
    }

    /// Fixed view (previews, shots): never touches core.
    init(account: AccountInfo) {
        _account = State(initialValue: account)
        fixed = true
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
            Section("Application") {
                LabeledContent("Version", value: AppIdentity.version)
                LabeledContent("Bundle ID", value: AppIdentity.bundleID)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .task {
            guard !fixed else { return }
            account = await Self.loadAccount()
        }
    }

    static func loadAccount() async -> AccountInfo {
        do {
            let st = try await Task.detached { try RustCore.status() }.value
            return AccountInfo.summarize(st)
        } catch {
            return .unavailable
        }
    }
}
