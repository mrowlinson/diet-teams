// CatchUpView.swift — om-catchup lane: sheet + Settings section.
//
// The sheet is the summarize/TL;DR/action-items entry point for long
// threads; the Settings section holds the provider picker + BYO key +
// base URL + model. Both show the provider's privacy note (cloud:
// thread text leaves the machine; on-device: never leaves the Mac).
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
    private let chatID: String?
    private let autoRun: Bool
    private let onDone: () -> Void

    /// - chatID: scopes the on-device summary cache to this thread
    ///   (nil still caches, keyed on message identity).
    /// - autoRun: summarize once on appear (the --show-catchup shot
    ///   hook only; real taps always come from the button).
    /// - onDone: Done / Esc tap. The host routes it through
    ///   `CatchUpSheet.dismissViaDone` (close + state reset).
    public init(
        catchUp: CatchUpStore, messages: [ChatMessage], chatID: String? = nil,
        autoRun: Bool = false, onDone: @escaping () -> Void = {}
    ) {
        self.catchUp = catchUp
        self.messages = messages
        self.chatID = chatID
        self.autoRun = autoRun
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.section) {
            HStack {
                Text("Thread catch-up")
                    .font(DietType.headline)
                Spacer(minLength: DietSpace.section)
                // Native macOS dismiss: a visible Done button that ALSO
                // owns .cancelAction, so Esc dismisses from any focus
                // (no focus trap). Summarize keeps .defaultAction (Return);
                // the two shortcuts never conflict.
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            Text(CatchUp.privacyNote(for: catchUp.config.provider))
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
            DietSeamH()
            stateBody
            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 440, height: 380)
        .task {
            if autoRun, catchUp.state == .idle {
                await catchUp.summarize(messages: messages, chatID: chatID)
            }
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch catchUp.state {
        case .idle:
            Text("Summarize \(messages.count) messages into a TL;DR, key points, and action items.")
                .font(DietType.body)
                .foregroundStyle(DietColor.textSecondaryColor)
            Button("Summarize") {
                Task { await catchUp.summarize(messages: messages, chatID: chatID) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!catchUp.config.enabled)
            if !catchUp.config.enabled {
                Text("Catch-up is off. Enable it in Settings to continue.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
        case .loading:
            HStack {
                Spacer()
                ProgressView("Summarizing…")
                Spacer()
            }
            .padding(.top, DietSpace.lg)
        case let .loaded(text):
            ScrollView {
                Text(text)
                    .font(DietType.body)
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
                .font(DietType.body)
                .foregroundStyle(Color(nsColor: DietColor.danger))
                .textSelection(.enabled)
            if catchUp.lastError == .cliMissing {
                CatchUpInstallPrompt()
            }
            if catchUp.lastError?.isOnDevice == true {
                CatchUpOnDeviceGuidance()
            }
            Button("Retry") {
                Task { await catchUp.summarize(messages: messages, chatID: chatID) }
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
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            Text("To use the OpenCode CLI provider:")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
            Text("1. Install: \(CatchUpCLI.installCommand)")
                .font(DietType.caption1)
                .monospaced()
                .textSelection(.enabled)
            Text("2. Sign in: \(CatchUpCLI.loginCommand)")
                .font(DietType.caption1)
                .monospaced()
                .textSelection(.enabled)
            if let url = URL(string: CatchUpCLI.installSite) {
                Link("Install opencode CLI", destination: url)
                    .font(DietType.caption1)
            }
        }
        .padding(DietSpace.sm)
        .background(DietColor.dividerColor)
        .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
    }
}

/// On-device unavailable guidance: what the Mac needs (macOS 26+,
/// Apple Silicon, Apple Intelligence on + downloaded). Shown in the
/// sheet's failed state for every on-device error.
public struct CatchUpOnDeviceGuidance: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            Text("To use on-device summaries, this Mac needs:")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
            Text("1. macOS 26 or later on Apple Silicon")
                .font(DietType.caption1)
                .textSelection(.enabled)
            Text("2. Apple Intelligence on (System Settings > Apple Intelligence & Siri)")
                .font(DietType.caption1)
                .textSelection(.enabled)
            Text("3. The on-device model download finished")
                .font(DietType.caption1)
                .textSelection(.enabled)
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
                        .foregroundStyle(
                            catchUp.cliAvailable
                                ? Color(nsColor: DietColor.success)
                                : Color(nsColor: DietColor.danger))
                    Button("Check again") {
                        catchUp.refreshCLIStatus()
                    }
                    .buttonStyle(.link)
                }
                .font(DietType.caption1)
                .onAppear {
                    catchUp.refreshCLIStatus()
                }
                if !catchUp.cliAvailable {
                    CatchUpInstallPrompt()
                }
            }
            // Dead-row trim (om-settings-trim): the CLI transport
            // ignores baseURL (exclusive routing: CLI-selected never
            // uses HTTPS, even with a key set), and the on-device
            // provider has no endpoint at all, so the row hides
            // exactly when it would do nothing.
            if CatchUp.usesBaseURL(
                provider: catchUp.config.provider, apiKey: catchUp.config.apiKey)
            {
                TextField("Base URL", text: $catchUp.config.baseURL)
                    .textSelection(.enabled)
            }
            // On-device uses the fixed system model: no Model row.
            if CatchUp.usesModel(provider: catchUp.config.provider) {
                TextField("Model", text: $catchUp.config.model)
                    .textSelection(.enabled)
            }
            if catchUp.config.provider == .onDevice {
                Text("No key, URL, or CLI needed — the system model runs on this Mac.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            } else {
                SecureField("API key", text: $catchUp.config.apiKey)
                Text("The key is kept in your Mac keychain, never on disk.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
                keyCaption
            }
            Text(CatchUp.privacyNote(for: catchUp.config.provider))
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        .onAppear {
            // Lazy key read lands here for Settings (init never
            // touches the keychain; launch stays prompt-free).
            catchUp.ensureKeyLoaded()
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
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        } else if keyEmpty {
            Text("Required — direct requests fail without a key.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }
}
