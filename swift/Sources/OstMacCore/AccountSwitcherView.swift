// AccountSwitcherView.swift — d1-accounts: native account switcher.
//
// A Menu in the status bar: one row per account (initials, name,
// AuthState dot, active checkmark) + Add Account… (native sheet
// hosting the shared AuthView on a pending per-profile VM). Removal
// lives in Settings (Accounts section, active marker + remove).
// Hidden in demo (single canned identity, shots stay stable).
import SwiftUI

/// One switcher row: observes its account's VM for the live state dot.
public struct AccountMenuRow: View {
    @ObservedObject var vm: AuthViewModel
    let record: AccountRecord
    let isActive: Bool

    public init(vm: AuthViewModel, record: AccountRecord, isActive: Bool) {
        self.vm = vm
        self.record = record
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AccountStateDot.color(for: vm.state))
                .frame(width: 8, height: 8)
            Text(AccountInitials.of(record.displayName))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(record.displayName).lineLimit(1)
                if let upn = record.upn, !upn.isEmpty {
                    Text(upn)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(accountLabel)
    }

    private var accountLabel: String {
        "\(record.displayName), \(AccountStateDot.label(for: vm.state))\(isActive ? ", active" : "")"
    }
}

/// AuthState → dot color + label (shared by the switcher + Settings).
public enum AccountStateDot {
    public static func color(for state: AuthState) -> Color {
        switch state {
        case .signedIn: .green
        case .expired, .refreshFailed: .red
        case .refreshing, .starting, .signingOut: .orange
        case .code, .polling, .browser, .browserWorking: .blue
        case .signedOut, .unknown, .error: .gray
        }
    }

    public static func label(for state: AuthState) -> String {
        switch state {
        case .unknown: "Checking…"
        case .signedOut: "Signed out"
        case .starting: "Starting…"
        case .code, .polling: "Waiting for browser sign-in…"
        case .browser, .browserWorking: "Browser sign-in…"
        case .signedIn: "Signed in"
        case .signingOut: "Signing out…"
        case .expired: "Expired"
        case .refreshing: "Refreshing…"
        case .refreshFailed(let message): "Refresh failed: \(message)"
        case .error(let message): message
        }
    }
}

/// Initials for the switcher/avatar label (first letters of the first
/// two words, uppercased; "?" when blank).
public enum AccountInitials {
    public static func of(_ displayName: String) -> String {
        let parts = displayName.split(whereSeparator: \.isWhitespace)
        let letters = parts.prefix(2).compactMap { $0.first }
        guard !letters.isEmpty else { return "?" }
        return String(letters).uppercased()
    }
}

public struct AccountSwitcherView: View {
    @ObservedObject var accounts: AccountStore
    var onSelect: (String) -> Void
    var onAdded: (AuthViewModel) -> Void
    /// gap-g2: account id to open beside the main window (no switch).
    var onOpenWindow: (String) -> Void

    @State private var pendingVM: AuthViewModel?
    @State private var showAdd = false

    public init(
        accounts: AccountStore,
        onSelect: @escaping (String) -> Void,
        onAdded: @escaping (AuthViewModel) -> Void,
        onOpenWindow: @escaping (String) -> Void = { _ in }
    ) {
        self.accounts = accounts
        self.onSelect = onSelect
        self.onAdded = onAdded
        self.onOpenWindow = onOpenWindow
    }

    public var body: some View {
        Menu {
            ForEach(accounts.accounts) { record in
                Button {
                    onSelect(record.id)
                } label: {
                    AccountMenuRow(
                        vm: accounts.vm(for: record.id), record: record,
                        isActive: record.id == accounts.activeID)
                }
                .disabled(record.id == accounts.activeID)
            }
            Divider()
            // gap-g2: side-by-side accounts (one window per account;
            // re-open refocuses). Listed separately so one-click switch
            // keeps working above.
            Menu("Open in New Window") {
                ForEach(accounts.accounts) { record in
                    Button(record.displayName) {
                        onOpenWindow(record.id)
                    }
                }
            }
            .disabled(accounts.accounts.isEmpty)
            Button("Add Account…") {
                pendingVM = accounts.beginAdd()
                showAdd = true
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(activeColor)
                    .frame(width: 8, height: 8)
                Text(activeLabel)
                    .font(.caption)
                    .lineLimit(1)
            }
            .help("Switch Teams account")
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("account-switcher")
        .sheet(isPresented: $showAdd) {
            if let vm = pendingVM {
                AddAccountSheet(vm: vm, onAdded: onAdded)
            }
        }
    }

    private var activeColor: Color {
        guard let id = accounts.activeID else { return .gray }
        return AccountStateDot.color(for: accounts.vm(for: id).state)
    }

    private var activeLabel: String {
        accounts.activeAccount?.displayName ?? "Accounts"
    }
}

/// Add-account sheet: the shared AuthView on a pending per-profile VM;
/// dismisses + reports on sign-in (the app completes the add).
public struct AddAccountSheet: View {
    @ObservedObject var vm: AuthViewModel
    var onAdded: (AuthViewModel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reported = false

    public init(vm: AuthViewModel, onAdded: @escaping (AuthViewModel) -> Void) {
        self.vm = vm
        self.onAdded = onAdded
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Add Teams Account")
                .font(.headline)
            AuthView(model: vm, embedded: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 320)
        .onReceive(vm.$state) { state in
            guard !reported, state.isSignedIn else { return }
            reported = true
            dismiss()
            onAdded(vm)
        }
    }
}
