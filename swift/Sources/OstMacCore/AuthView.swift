// AuthView.swift — om-authux lane: state-driven sign-in view.
//
// Renders AuthViewModel.state: signed-out -> code (copy + open-browser)
// -> polling spinner -> signed-in, plus sign-out and token-expiry/refresh
// failure states with retry. The browser step is user-driven (no automation).
import SwiftUI

public struct AuthView: View {
    @ObservedObject public var model: AuthViewModel

    public init(model: AuthViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .unknown:
                ProgressView("Checking session…")
            case .signedOut:
                signedOut
            case .starting:
                ProgressView("Contacting Microsoft…")
            case let .code(info):
                codeView(info: info, attempts: nil)
            case let .polling(info, attempts):
                codeView(info: info, attempts: attempts)
            case .signedIn:
                signedIn
            case .signingOut:
                ProgressView("Signing out…")
            case .expired:
                expired(message: nil)
            case .refreshing:
                ProgressView("Refreshing session…")
            case let .refreshFailed(message):
                expired(message: message)
            case let .error(message):
                errorView(message: message)
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 420)
    }

    // MARK: - States

    private var signedOut: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Sign in to Teams")
                .font(.title2).bold()
            Text("Uses a browser sign-in code. Your session persists across launches.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign in") { Task { await model.signIn() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func codeView(info: AuthCodeInfo, attempts: Int?) -> some View {
        VStack(spacing: 12) {
            Text("Sign in to Teams")
                .font(.title2).bold()
            if attempts != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser sign-in…\(attemptText(attempts!))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Open the sign-in page and enter this code:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(info.userCode)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 4)
            Text(info.verificationURI)
                .font(.caption).monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button(model.copied ? "Copied ✓" : "Copy code") { model.copyCode() }
                    .buttonStyle(.bordered)
                Button("Open browser") { model.openBrowser() }
                    .buttonStyle(.borderedProminent)
            }
            if attempts == nil {
                Button("I've opened it — start checking") { model.startChecking() }
                    .buttonStyle(.link)
                    .font(.callout)
            } else {
                Button("Reopen browser page") { model.openBrowser() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Button("Cancel") { model.cancel() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
    }

    private func attemptText(_ n: Int) -> String {
        n > 0 ? " (check \(n + 1))" : ""
    }

    private var signedIn: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Signed in")
                .font(.title2).bold()
            Text("Session is saved and reused across launches.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Sign out") { Task { await model.signOut() } }
                .buttonStyle(.bordered)
        }
    }

    private func expired(message: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Session expired")
                .font(.title2).bold()
            Text(message ?? "Your sign-in expired. Try refreshing, or sign in again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Retry refresh") { Task { await model.retryRefresh() } }
                    .buttonStyle(.borderedProminent)
                Button("Sign in again") { Task { await model.signIn() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Something went wrong")
                .font(.title2).bold()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Try again") { Task { await model.retry() } }
                    .buttonStyle(.borderedProminent)
                Button("Back") { model.cancel() }
                    .buttonStyle(.bordered)
            }
        }
    }
}
