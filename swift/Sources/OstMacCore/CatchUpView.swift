// CatchUpView.swift — om-catchup lane: sheet + Settings section.
//
// The sheet is the summarize/TL;DR/action-items entry point for long
// threads; the Settings section holds the provider picker + BYO key +
// base URL + model. Both show the privacy note (thread text leaves
// the machine).
//
// om-catchup-sheet-dismiss: presented as a popover (a window-modal
// sheet cannot dismiss on click-outside) with Done + Esc +
// click-outside dismiss; every close resets the summary state.
import AppKit
import DietDesign
import SwiftUI

// MARK: - Sheet dismissal routing

/// One funnel for every catch-up dismiss intent. `close(presented:store:)`
/// closes the presentation AND resets the summary state, so a reopen
/// always starts from `.idle`. Each intent keeps its own entry point so
/// regression tests pin all three paths:
///   - Done button → `dismissViaDone`
///   - Esc (`.onExitCommand`, fires from any focus — no trap) →
///     `dismissViaEscape`
///   - click-outside / any other system dismiss (binding `onChange`) →
///     `dismissViaClickOutside`
///
/// All three are idempotent: dismissing an already-closed sheet is a
/// no-op that still leaves the store at `.idle`.
@MainActor
public enum CatchUpSheet {
    public static func open(presented: Binding<Bool>, store: CatchUpStore) {
        store.reset()
        presented.wrappedValue = true
    }

    public static func dismissViaDone(presented: Binding<Bool>, store: CatchUpStore) {
        close(presented: presented, store: store)
    }

    public static func dismissViaEscape(presented: Binding<Bool>, store: CatchUpStore) {
        close(presented: presented, store: store)
    }

    public static func dismissViaClickOutside(presented: Binding<Bool>, store: CatchUpStore) {
        close(presented: presented, store: store)
    }

    private static func close(presented: Binding<Bool>, store: CatchUpStore) {
        presented.wrappedValue = false
        store.reset()
    }
}

/// Sheet content: one Summarize tap → TL;DR/key-points/action-items.
public struct CatchUpView: View {
    @ObservedObject private var catchUp: CatchUpStore
    private let messages: [ChatMessage]
    private let autoRun: Bool
    private let onDone: () -> Void

    /// - autoRun: summarize once on appear (the --show-catchup shot
    ///   hook only; real taps always come from the button).
    /// - onDone: Done / Esc tap. The host routes it through
    ///   `CatchUpSheet.dismissViaDone` (close + state reset).
    public init(
        catchUp: CatchUpStore, messages: [ChatMessage], autoRun: Bool = false,
        onDone: @escaping () -> Void = {}
    ) {
        self.catchUp = catchUp
        self.messages = messages
        self.autoRun = autoRun
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Thread catch-up")
                    .font(.headline)
                Spacer(minLength: 12)
                // Native macOS dismiss: a visible Done button that ALSO
                // owns .cancelAction, so Esc dismisses from any focus
                // (no focus trap). Summarize keeps .defaultAction (Return);
                // the two shortcuts never conflict.
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            Text(CatchUp.privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            stateBody
            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 440, height: 380)
        .task {
            if autoRun, catchUp.state == .idle {
                await catchUp.summarize(messages: messages)
            }
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch catchUp.state {
        case .idle:
            Text("Summarize \(messages.count) messages into a TL;DR, key points, and action items.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Summarize") {
                Task { await catchUp.summarize(messages: messages) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!catchUp.config.enabled)
            if !catchUp.config.enabled {
                Text("Catch-up is off. Enable it in Settings to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack {
                Spacer()
                ProgressView("Summarizing…")
                Spacer()
            }
            .padding(.top, 24)
        case let .loaded(text):
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.link)
        case let .failed(detail):
            Text(detail)
                .font(.body)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            if catchUp.lastError == .cliMissing {
                CatchUpInstallPrompt()
            }
            Button("Retry") {
                Task { await catchUp.summarize(messages: messages) }
            }
            .buttonStyle(.link)
        }
    }
}

/// Missing-CLI install prompt: what to run + where to get it. Shown
/// in the sheet's failed state and in Settings when the CLI provider
/// is selected but the binary is missing.
public struct CatchUpInstallPrompt: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("To use the OpenCode CLI provider:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("1. Install: \(CatchUpCLI.installCommand)")
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
            Text("2. Sign in: \(CatchUpCLI.loginCommand)")
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
            if let url = URL(string: CatchUpCLI.installSite) {
                Link("Install opencode CLI", destination: url)
                    .font(.caption)
            }
        }
        .padding(DietSpace.sm)
        .background(DietColor.dividerColor)
        .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
    }
}

/// Settings section: enable toggle + BYO endpoint fields. OFF default.
public struct CatchUpSettingsSection: View {
    @ObservedObject private var catchUp: CatchUpStore

    public init(catchUp: CatchUpStore) {
        self.catchUp = catchUp
    }

    public var body: some View {
        Section("Thread catch-up") {
            Toggle("Enable AI catch-up", isOn: $catchUp.config.enabled)
            Picker("Provider", selection: $catchUp.config.provider) {
                ForEach(CatchUpProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: catchUp.config.provider) { _, provider in
                catchUp.selectProvider(provider)
            }
            if catchUp.config.provider == .openCodeCLI {
                HStack {
                    Text("opencode CLI")
                    Spacer()
                    Text(catchUp.cliAvailable ? "Found" : "Missing")
                        .foregroundStyle(catchUp.cliAvailable ? .green : .red)
                    Button("Check again") {
                        catchUp.refreshCLIStatus()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .onAppear {
                    catchUp.refreshCLIStatus()
                }
                if !catchUp.cliAvailable {
                    CatchUpInstallPrompt()
                }
            }
            // Dead-row trim (om-settings-trim): the CLI transport
            // ignores baseURL (exclusive routing: CLI-selected never
            // uses HTTPS, even with a key set), so the row hides
            // exactly when it would do nothing.
            if CatchUp.usesBaseURL(
                provider: catchUp.config.provider, apiKey: catchUp.config.apiKey)
            {
                TextField("Base URL", text: $catchUp.config.baseURL)
                    .textSelection(.enabled)
            }
            TextField("Model", text: $catchUp.config.model)
            SecureField("API key", text: $catchUp.config.apiKey)
            Text("The key is kept in your Mac keychain, never on disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
            keyCaption
            Text(CatchUp.privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Key-status caption: the CLI note asserts exclusive routing (a
    /// saved key never switches the CLI provider to HTTPS — it
    /// applies to the direct providers); direct providers require a
    /// key.
    @ViewBuilder
    private var keyCaption: some View {
        let keyEmpty = catchUp.config.apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if catchUp.config.provider == .openCodeCLI {
            Text("CLI-only: shells out to opencode (your `opencode auth login`, free tier) and never uses HTTPS. A saved key applies to the direct providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if keyEmpty {
            Text("Required — direct requests fail without a key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
