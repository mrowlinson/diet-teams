// AuthView.swift — om-authux lane: state-driven sign-in view.
//
// Renders AuthViewModel.state: signed-out -> code (copy + open-browser)
// -> polling spinner -> signed-in, plus sign-out and token-expiry/refresh
// failure states with retry. The browser step is user-driven (no automation).
//
// om-reskin-chrome: Diet tokens only — DietType/DietSpace/DietColor,
// .dietPrimary/.dietSecondary buttons, link actions in accent.
import DietDesign
import SwiftUI

public struct AuthView: View {
    @ObservedObject public var model: AuthViewModel

    public init(model: AuthViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: DietSpace.md) {
            switch model.state {
            case .unknown:
                DietProgressLabel("Checking session…")
            case .signedOut:
                signedOut
            case .starting:
                DietProgressLabel("Contacting Microsoft…")
            case let .code(info):
                codeView(info: info, attempts: nil)
            case let .polling(info, attempts):
                codeView(info: info, attempts: attempts)
            case let .browser(info):
                if model.isDemo {
                    BrowserSignInDemoView(info: info) { model.cancelBrowser() }
                } else {
                    BrowserSignInView(
                        info: info,
                        onRedirect: { url in Task { await model.completeBrowserSignIn(callbackURL: url) } },
                        onCancel: { model.cancelBrowser() })
                }
            case .browserWorking:
                DietProgressLabel("Completing browser sign-in…")
            case .signedIn:
                signedIn
            case .signingOut:
                DietProgressLabel("Signing out…")
            case .expired:
                expired(message: nil)
            case .refreshing:
                DietProgressLabel("Refreshing session…")
            case let .refreshFailed(message):
                expired(message: message)
            case let .error(message):
                errorView(message: message)
            }
        }
        .padding(DietSpace.lg)
        .frame(minWidth: 360, minHeight: 420)
        // No fill: the host (Auth window, gate, Settings card) owns bg.
    }

    // MARK: - States

    private var signedOut: some View {
        VStack(spacing: DietSpace.sm) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: DietSize.avatarLG))
                .foregroundStyle(DietColor.textSecondaryColor)
            Text("Sign in to Teams")
                .font(DietType.title2).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            Text("Uses a browser sign-in code. Your session persists across launches.")
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
                .multilineTextAlignment(.center)
            Button("Sign in") { Task { await model.signIn() } }
                .buttonStyle(.dietPrimary)
                .padding(.top, DietSpace.xs)
            Button("Device code not working? Use browser sign-in") {
                Task { await model.startBrowserSignIn() }
            }
            .buttonStyle(.link)
            .font(DietType.callout)
        }
    }

    private func codeView(info: AuthCodeInfo, attempts: Int?) -> some View {
        VStack(spacing: DietSpace.sm) {
            Text("Sign in to Teams")
                .font(DietType.title2).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            if attempts != nil {
                HStack(spacing: DietSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser sign-in…\(attemptText(attempts!))")
                        .font(DietType.callout)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            } else {
                Text("Open the sign-in page and enter this code:")
                    .font(DietType.callout)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            Text(info.userCode)
                .font(DietType.largeTitle.monospaced().bold())
                .foregroundStyle(DietColor.textPrimaryColor)
                .textSelection(.enabled)
                .padding(.vertical, DietSpace.xs)
            Text(info.verificationURI)
                .font(DietType.captionMono)
                .foregroundStyle(DietColor.textSecondaryColor)
                .textSelection(.enabled)
            HStack(spacing: DietSpace.sm) {
                Button(model.copied ? "Copied ✓" : "Copy code") { model.copyCode() }
                    .buttonStyle(.dietSecondary)
                Button("Open browser") { model.openBrowser() }
                    .buttonStyle(.dietPrimary)
            }
            .padding(.top, DietSpace.xs)
            if attempts == nil {
                Button("I've opened it — start checking") { model.startChecking() }
                    .buttonStyle(.link)
                    .font(DietType.callout)
            } else {
                Button("Reopen browser page") { model.openBrowser() }
                    .buttonStyle(.link)
                    .font(DietType.callout)
            }
            Button("Cancel") { model.cancel() }
                .buttonStyle(.link)
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }

    private func attemptText(_ n: Int) -> String {
        n > 0 ? " (check \(n + 1))" : ""
    }

    private var signedIn: some View {
        VStack(spacing: DietSpace.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: DietSize.avatarLG))
                .foregroundStyle(Color(nsColor: DietColor.success))
            Text("Signed in")
                .font(DietType.title2).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            Text("Session is saved and reused across launches.")
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
            Button("Sign out") { Task { await model.signOut() } }
                .buttonStyle(.dietSecondary)
                .padding(.top, DietSpace.xs)
        }
    }

    private func expired(message: String?) -> some View {
        VStack(spacing: DietSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DietSize.avatarLG))
                .foregroundStyle(Color(nsColor: DietColor.warning))
            Text("Session expired")
                .font(DietType.title2).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            Text(message ?? "Your sign-in expired. Try refreshing, or sign in again.")
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: DietSpace.sm) {
                Button("Retry refresh") { Task { await model.retryRefresh() } }
                    .buttonStyle(.dietPrimary)
                Button("Sign in again") { Task { await model.signIn() } }
                    .buttonStyle(.dietSecondary)
            }
            .padding(.top, DietSpace.xs)
            Button("Use browser sign-in instead") {
                Task { await model.startBrowserSignIn() }
            }
            .buttonStyle(.link)
            .font(DietType.callout)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: DietSpace.sm) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: DietSize.avatarLG))
                .foregroundStyle(Color(nsColor: DietColor.danger))
            Text("Something went wrong")
                .font(DietType.title2).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            Text(message)
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: DietSpace.sm) {
                Button("Try again") { Task { await model.retry() } }
                    .buttonStyle(.dietPrimary)
                Button("Back") { model.cancel() }
                    .buttonStyle(.dietSecondary)
            }
            .padding(.top, DietSpace.xs)
            Button("Try browser sign-in instead") {
                Task { await model.startBrowserSignIn() }
            }
            .buttonStyle(.link)
            .font(DietType.callout)
        }
    }
}

/// Labeled spinner for the transient AuthViewModel states.
struct DietProgressLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: DietSpace.sm) {
            ProgressView()
            Text(text)
                .font(DietType.callout)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
    }
}
