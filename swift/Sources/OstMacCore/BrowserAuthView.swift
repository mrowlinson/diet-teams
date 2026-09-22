// BrowserAuthView.swift — om-pwauth lane: native browser-capture sign-in.
//
// WKWebView (persistent default data store) loads the core's authorize URL;
// the navigation delegate intercepts the nativeclient redirect and hands
// the full callback URL to the core for state-verify + code exchange.
// Chose WKWebView over ASWebAuthenticationSession: the persistent cookie
// jar keeps SSO sessions, so repeat browser sign-ins are near-silent and
// there is no app-switch. Silent headless re-auth stays on the refresh
// path (stored refresh token, no UI); this view is the explicit fallback.
//
// No Playwright/Chromium helper: native capture covers MFA/SSO/conditional
// access (full interactive login), with far less to ship and sign.
import SwiftUI
import WebKit

/// Redirect-hit test: the webview URL starts with the core's redirect URI.
/// Case-insensitive on the scheme+host (login flows vary the case); the
/// code/state parse + state verify happen in core, never here.
public func isBrowserRedirect(_ urlString: String, redirectURI: String) -> Bool {
    let url = urlString.lowercased()
    let prefix = redirectURI.lowercased()
    guard url.hasPrefix(prefix) else { return false }
    // Boundary: exact hit or ?query/#fragment follows (no host-suffix game).
    let rest = url.dropFirst(prefix.count)
    return rest.isEmpty || rest.hasPrefix("?") || rest.hasPrefix("#") || rest.hasPrefix("/")
}

/// WKWebView that reports the nativeclient redirect instead of loading it.
/// Persistent `WKWebsiteDataStore.default()` = SSO cookies survive across
/// launches (repeat sign-ins skip the password when the session is alive).
public struct BrowserAuthWebView: NSViewRepresentable {
    public let authorizeURL: String
    public let redirectURI: String
    public let onRedirect: (String) -> Void

    public init(authorizeURL: String, redirectURI: String, onRedirect: @escaping (String) -> Void) {
        self.authorizeURL = authorizeURL
        self.redirectURI = redirectURI
        self.onRedirect = onRedirect
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(redirectURI: redirectURI, onRedirect: onRedirect)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        if let url = URL(string: authorizeURL) {
            view.load(URLRequest(url: url))
        }
        return view
    }

    public func updateNSView(_ view: WKWebView, context: Context) {}

    public final class Coordinator: NSObject, WKNavigationDelegate {
        private let redirectURI: String
        private let onRedirect: (String) -> Void
        private var fired = false

        init(redirectURI: String, onRedirect: @escaping (String) -> Void) {
            self.redirectURI = redirectURI
            self.onRedirect = onRedirect
        }

        private func intercept(_ url: URL?) -> Bool {
            guard !fired, let raw = url?.absoluteString,
                  isBrowserRedirect(raw, redirectURI: redirectURI)
            else { return false }
            fired = true
            onRedirect(raw)
            return true
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if intercept(navigationAction.request.url) {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        // Fallback: nativeclient is not a real page, so a missed policy
        // decision surfaces here — still harvest the code from the URL.
        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            _ = intercept(webView.url)
        }
    }
}

/// Full browser sign-in card: webview + cancel. The host drives
/// `completeBrowserSignIn` from `onRedirect`.
public struct BrowserSignInView: View {
    public let info: AuthBrowserInfo
    public let onRedirect: (String) -> Void
    public let onCancel: () -> Void

    public init(info: AuthBrowserInfo, onRedirect: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.info = info
        self.onRedirect = onRedirect
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Browser sign-in")
                .font(.title2).bold()
            Text("Sign in with your work account — supports MFA and SSO. Session cookies persist for faster repeat sign-ins.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            BrowserAuthWebView(
                authorizeURL: info.authorizeURL,
                redirectURI: info.redirectURI,
                onRedirect: onRedirect)
                .frame(minWidth: 420, minHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1))
            Button("Cancel") { onCancel() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
    }
}

/// Demo placeholder (screenshots): the offline stand-in for the webview.
/// Never loads a URL — network stays untouched in demo/shots.
public struct BrowserSignInDemoView: View {
    public let info: AuthBrowserInfo
    public let onCancel: () -> Void

    public init(info: AuthBrowserInfo, onCancel: @escaping () -> Void) {
        self.info = info
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Browser sign-in")
                .font(.title2).bold()
            Text("Sign in with your work account — supports MFA and SSO. Session cookies persist for faster repeat sign-ins.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                Text("Microsoft sign-in page loads here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(info.authorizeURL)
                    .font(.caption).monospaced()
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 420, minHeight: 380)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button("Cancel") { onCancel() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
    }
}
