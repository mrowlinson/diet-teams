// CatchUpView.swift — om-catchup lane: sheet + Settings section.
//
// The sheet is the summarize/TL;DR/action-items entry point for long
// threads; the Settings section holds the provider picker + BYO key +
// base URL + model. Both show the privacy note (thread text leaves
// the machine).
import AppKit
import SwiftUI

/// Sheet content: one Summarize tap → TL;DR/key-points/action-items.
public struct CatchUpView: View {
    @ObservedObject private var catchUp: CatchUpStore
    private let messages: [ChatMessage]
    private let autoRun: Bool

    /// - autoRun: summarize once on appear (the --show-catchup shot
    ///   hook only; real taps always come from the button).
    public init(catchUp: CatchUpStore, messages: [ChatMessage], autoRun: Bool = false) {
        self.catchUp = catchUp
        self.messages = messages
        self.autoRun = autoRun
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thread catch-up")
                .font(.headline)
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
            Button("Retry") {
                Task { await catchUp.summarize(messages: messages) }
            }
            .buttonStyle(.link)
        }
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
            TextField("Base URL", text: $catchUp.config.baseURL)
                .textSelection(.enabled)
            TextField("Model", text: $catchUp.config.model)
            SecureField("API key", text: $catchUp.config.apiKey)
            Text("The key is kept in your Mac keychain, never on disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(CatchUp.privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
