// TeamsFrame.swift — teams-frame PROTOTYPE: host teams.microsoft.com in a
// WKWebView so third-party Teams apps render on one native surface.
//
// DISPLAY ONLY (real employer account): never send messages, never click
// inside apps post-login, never drive an authenticated session. Pre-login
// automation OK. Owner completes login live; see tmp/TEAMS-FRAME-PROTO-PROOF.md.
//
// v0 scope: one surface, one deep link (--teams-frame-url). Crop hides the
// Teams left rail + top header (estimates — UNMEASURED until owner login;
// --teams-frame-full bypasses). Escape interception LOGS and allows
// (observe, don't yank). No preload; exit arms a keep-alive timer
// (UserDefaults teamsFrameKeepAliveMinutes, default 15, 0 = instant).
// No camera/mic entitlement changes (media gaps documented in proof).
import SwiftUI
import WebKit

public extension Notification.Name {
    /// App-menu "Kill App Frame" → instant frame destroy.
    static let killTeamsFrame = Notification.Name("dev.ostmac.teamsFrame.kill")
}

// MARK: - Config (pure; unit-tested)

public enum TeamsFrameConfig {
    public static let defaultURL = "https://teams.microsoft.com"
    /// Own persistent jar: Teams cookies survive relaunch, isolated from
    /// the BrowserAuthView default store. Fixed UUID = stable across runs.
    public static let dataStoreIdentifier = UUID(
        uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    public static let keepAliveMinutesKey = "teamsFrameKeepAliveMinutes"
    public static let defaultKeepAliveMinutes = 15

    /// --teams-frame-url <url>; default https://teams.microsoft.com.
    /// Owner pastes the entity deep link at test time.
    public static func launchURL(args: [String]) -> String {
        if let i = args.firstIndex(of: "--teams-frame-url"), i + 1 < args.count {
            return args[i + 1]
        }
        return defaultURL
    }

    /// Frame window opens when either flag is present.
    public static func shouldOpen(args: [String]) -> Bool {
        args.contains("--show-teams-frame") || args.contains("--teams-frame-url")
    }

    /// --teams-frame-full shows the uncropped page (fallback).
    public static func fullFrame(args: [String]) -> Bool {
        args.contains("--teams-frame-full")
    }

    /// UA suffix: stock WKWebView omits the `Version/… Safari/…` tokens
    /// and Teams serves /v2/unsupported-browser. Appending Safari tokens
    /// (truthful engine) gets the real app.
    public static let userAgentSuffix = "Version/17.4 Safari/605.1.15"

    /// Prototype allowlist: Teams hosts + Microsoft auth/content hosts
    /// third-party apps need. Subdomains match via boundary suffix.
    public static let allowedHostSuffixes = [
        "teams.microsoft.com",
        "teams.live.com",
        "login.microsoftonline.com",
        "microsoftonline.com",
        "login.live.com",
        "live.com",
        "office.com",
        "office.net",
        "sharepoint.com",
        "onedrive.com",
    ]

    /// Host allowlist check. `about:blank` (no host, e.g. fresh webview)
    /// is allowed; every other hostless URL is not.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return url.scheme?.lowercased() == "about"
        }
        for suffix in allowedHostSuffixes {
            if host == suffix || host.hasSuffix("." + suffix) { return true }
        }
        return false
    }

    /// Keep-alive minutes seam (UserDefaults; default 15, 0 = instant).
    public static func keepAliveMinutes(defaults: UserDefaults) -> Int {
        if defaults.object(forKey: keepAliveMinutesKey) == nil {
            return defaultKeepAliveMinutes
        }
        return defaults.integer(forKey: keepAliveMinutesKey)
    }
}

// MARK: - Crop v0 (UNMEASURED estimates)

/// Native clip insets hiding the Teams left rail + top header.
/// ESTIMATES (left 68, top 48 @1x from public Teams-web layout) —
/// NOT measured live: the login page shows no Teams chrome, and only
/// the owner may drive an authenticated session. Measure post-login
/// (see proof protocol) and update `v0` + this doc.
public struct TeamsFrameCrop: Equatable {
    public var left: CGFloat
    public var top: CGFloat

    public init(left: CGFloat, top: CGFloat) {
        self.left = left
        self.top = top
    }

    public static let v0 = TeamsFrameCrop(left: 68, top: 48)
    public static let none = TeamsFrameCrop(left: 0, top: 0)
}

// MARK: - Lifecycle store

/// Owns the dedicated WKProcessPool + data store. destroy() nils both —
/// the dedicated pool orphans its web processes, releasing the frame.
/// Test seams: injectable UserDefaults, `keepAliveArmed` readback.
@MainActor
public final class TeamsFrameStore: ObservableObject {
    @Published public var alive = true
    // Published: activate() runs in onAppear (after first body eval) —
    // the publishes re-evaluate the body and create the webview.
    @Published public private(set) var pool: WKProcessPool?
    @Published public private(set) var dataStore: WKWebsiteDataStore?
    public private(set) var keepAliveArmed = false
    private var timer: Timer?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var keepAliveMinutes: Int {
        TeamsFrameConfig.keepAliveMinutes(defaults: defaults)
    }

    /// Surface entry: (re)build the pool + store, cancel pending destroy.
    public func activate() {
        timer?.invalidate()
        timer = nil
        keepAliveArmed = false
        if pool == nil { pool = WKProcessPool() }
        if dataStore == nil {
            dataStore = WKWebsiteDataStore(
                forIdentifier: TeamsFrameConfig.dataStoreIdentifier)
        }
        if !alive { alive = true }
        print("[teams-frame] activate (keepAlive \(keepAliveMinutes) min)")
    }

    /// Surface exit: destroy now (0) or arm the keep-alive timer.
    public func deactivate() {
        let mins = keepAliveMinutes
        if mins <= 0 {
            print("[teams-frame] deactivate: keepAlive 0 → destroy")
            destroy()
            return
        }
        timer?.invalidate()
        keepAliveArmed = true
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(mins * 60), repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                print("[teams-frame] keep-alive expired → destroy")
                self?.destroy()
            }
        }
        print("[teams-frame] deactivate: destroy in \(mins) min")
    }

    /// Instant destroy: nil the view inputs; the dedicated pool orphans
    /// its processes. Menu "Kill App Frame" lands here.
    public func destroy() {
        timer?.invalidate()
        timer = nil
        keepAliveArmed = false
        pool = nil
        dataStore = nil
        alive = false
        print("[teams-frame] DESTROYED (pool orphaned)")
    }
}

// MARK: - Webview (NSViewRepresentable)

/// Teams webview: dedicated process pool + own persistent data store.
/// Navigation delegate LOGS allowlist escapes and allows them
/// (prototype observe-don't-yank). Stock delegates otherwise — no
/// SSO-popup/download handlers beyond default (documented gap).
public struct TeamsFrameWebView: NSViewRepresentable {
    public let urlString: String
    public let pool: WKProcessPool
    public let dataStore: WKWebsiteDataStore

    public init(urlString: String, pool: WKProcessPool, dataStore: WKWebsiteDataStore) {
        self.urlString = urlString
        self.pool = pool
        self.dataStore = dataStore
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = pool
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = TeamsFrameConfig.userAgentSuffix
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        if let url = URL(string: urlString) {
            print("[teams-frame] webview created, loading \(urlString)")
            view.load(URLRequest(url: url))
        } else {
            print("[teams-frame] BAD URL STRING: \(urlString)")
        }
        return view
    }

    public func updateNSView(_ view: WKWebView, context: Context) {}

    public final class Coordinator: NSObject, WKNavigationDelegate {
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               !TeamsFrameConfig.isAllowed(url)
            {
                // v0: LOG the escape, still allow (observe, don't yank).
                print("[teams-frame] ESCAPE (allowed, prototype): \(url.absoluteString)")
            }
            decisionHandler(.allow)
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[teams-frame] started: \(webView.url?.absoluteString ?? "?")")
        }

        // Load readback (owner-login protocol: proves the frame fetched).
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[teams-frame] loaded: \(webView.url?.absoluteString ?? "?")")
        }

        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            print("[teams-frame] load failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Window content

/// Frame window: cropped webview while `store.alive`, placeholder after
/// destroy (Reopen rebuilds via activate — no relaunch needed).
public struct TeamsFrameWindow: View {
    @ObservedObject public var store: TeamsFrameStore
    public let urlString: String
    public let crop: TeamsFrameCrop

    public init(store: TeamsFrameStore, urlString: String, crop: TeamsFrameCrop) {
        self.store = store
        self.urlString = urlString
        self.crop = crop
    }

    public var body: some View {
        Group {
            if store.alive, let pool = store.pool, let dataStore = store.dataStore {
                GeometryReader { geo in
                    TeamsFrameWebView(urlString: urlString, pool: pool, dataStore: dataStore)
                        .frame(
                            width: geo.size.width + crop.left,
                            height: geo.size.height + crop.top)
                        .offset(x: -crop.left, y: -crop.top)
                }
                .clipped()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "app.window.on.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("App frame destroyed")
                        .font(.headline)
                    Text("The Teams web processes were released.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Reopen Frame") { store.activate() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
        .onReceive(NotificationCenter.default.publisher(for: .killTeamsFrame)) { _ in
            store.destroy()
        }
    }
}
