// TeamsFrame.swift — teams-frame FULL: host teams.microsoft.com in a
// WKWebView so third-party Teams apps render on one native surface.
//
// DISPLAY ONLY (real employer account): never send messages, never click
// inside apps post-login, never drive an authenticated session. Pre-login
// automation OK. Owner completes login live; see tmp/TEAMS-FRAME-FULL-PROOF.md.
//
// Full scope: app registry (UserDefaults JSON) + native switcher Picker
// loading entity links in the SAME dedicated frame (no re-auth); escapes
// YANKED (cancel + Open-in-Browser alert); WKUIDelegate SSO popups as a
// modal sheet + native JS panels; download save panel (~/Downloads);
// lazy init + hide suspends (stopLoading) + destroy logs resident MB;
// --teams-frame-calibrate crop guide overlay. No preload, no process
// prewarm (deliberate — see TeamsFrameStore), no entitlement changes.
import AppKit
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

    /// --teams-frame-calibrate overlays draggable crop guides (debug aid;
    /// owner measures post-login, values print to stdout).
    public static func calibrate(args: [String]) -> Bool {
        args.contains("--teams-frame-calibrate")
    }

    /// UA suffix: stock WKWebView omits the `Version/… Safari/…` tokens
    /// and Teams serves /v2/unsupported-browser. Appending Safari tokens
    /// (truthful engine) gets the real app.
    public static let userAgentSuffix = "Version/17.4 Safari/605.1.15"

    /// Allowlist: Teams hosts + Microsoft auth/content hosts
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

    /// Escape decision matrix (pure; the coordinator executes it).
    /// Allowed → pass. Non-allowlisted top-level nav → yank (cancel +
    /// Open-in-Browser offer). Non-allowlisted subframe (app iframes,
    /// CDNs) → log + allow (yanking iframes would break apps).
    public static func escapeDecision(url: URL, isMainFrame: Bool) -> TeamsFrameEscapeDecision {
        if isAllowed(url) { return .allow }
        return isMainFrame ? .yank : .allowLogged
    }

    /// Popup intercept: only target-less opens (window.open / _blank,
    /// e.g. SSO) go to the sheet; in-frame targets stay put.
    public static func interceptsPopup(targetFrameIsNil: Bool) -> Bool {
        targetFrameIsNil
    }

    /// Unexpanded registry placeholder (the seed's `<APP_ENTITY_ID>` or
    /// any raw `<…>` token): unloadable (URL(string:) fails on angle
    /// brackets), so the window shows a guidance view instead of a
    /// blank frame. Owner pastes a real entity link via the URL entry.
    public static func isPlaceholderURL(_ raw: String) -> Bool {
        raw.contains("<") || raw.contains(">")
    }

    /// Keep-alive minutes seam (UserDefaults; default 15, 0 = instant).
    public static func keepAliveMinutes(defaults: UserDefaults) -> Int {
        if defaults.object(forKey: keepAliveMinutesKey) == nil {
            return defaultKeepAliveMinutes
        }
        return defaults.integer(forKey: keepAliveMinutesKey)
    }
}

/// Outcome of the escape decision matrix.
public enum TeamsFrameEscapeDecision: Equatable {
    case allow
    case allowLogged
    case yank
}

// MARK: - Crop (per-app, Codable; nil → v0 default)

/// Native clip insets hiding the Teams left rail + top header.
/// v0 (left 68, top 48 @1x) are ESTIMATES from public Teams-web layout —
/// NOT measured live until the owner calibrates post-login
/// (--teams-frame-calibrate). Per-app overrides live on TeamsFrameApp.
public struct TeamsFrameCrop: Equatable, Codable {
    public var left: CGFloat
    public var top: CGFloat

    public init(left: CGFloat, top: CGFloat) {
        self.left = left
        self.top = top
    }

    public static let v0 = TeamsFrameCrop(left: 68, top: 48)
    public static let none = TeamsFrameCrop(left: 0, top: 0)
}

// MARK: - App registry (UserDefaults JSON; unit-tested)

/// One third-party Teams app: entity deep link + optional crop override.
/// `crop == nil` → TeamsFrameCrop.v0.
public struct TeamsFrameApp: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var entityURL: String
    public var crop: TeamsFrameCrop?

    public init(id: String, label: String, entityURL: String, crop: TeamsFrameCrop? = nil) {
        self.id = id
        self.label = label
        self.entityURL = entityURL
        self.crop = crop
    }

    public var effectiveCrop: TeamsFrameCrop { crop ?? .v0 }
}

/// JSON-in-UserDefaults store. Missing/corrupt/empty → seed (one
/// placeholder entry, no real org URLs — owner pastes real entity links).
public enum TeamsFrameRegistry {
    public static let appsKey = "teamsFrameApps"
    public static let selectedAppKey = "teamsFrameSelectedAppID"

    public static let seedApps = [
        TeamsFrameApp(
            id: "sample-app",
            label: "Sample App",
            entityURL: "https://teams.microsoft.com/l/entity/<APP_ENTITY_ID>?label=Sample")
    ]

    public static func loadApps(defaults: UserDefaults) -> [TeamsFrameApp] {
        guard let data = defaults.data(forKey: appsKey),
              let apps = try? JSONDecoder().decode([TeamsFrameApp].self, from: data),
              !apps.isEmpty
        else { return seedApps }
        return apps
    }

    public static func saveApps(_ apps: [TeamsFrameApp], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        defaults.set(data, forKey: appsKey)
    }

    public static func loadSelectedID(defaults: UserDefaults) -> String? {
        defaults.string(forKey: selectedAppKey)
    }

    public static func saveSelectedID(_ id: String?, defaults: UserDefaults) {
        if let id {
            defaults.set(id, forKey: selectedAppKey)
        } else {
            defaults.removeObject(forKey: selectedAppKey)
        }
    }
}

// MARK: - Footprint (best-effort resident MB; unit-tested for safety)

/// Process resident size via task_info. Decimal MB (matches Activity
/// Monitor). Nil on any failure — destroy() logs "unknown", never crashes.
public enum TeamsFrameFootprint {
    public static func residentMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1_000_000
    }
}

// MARK: - Downloads (pure seams; unit-tested)

public enum TeamsFrameDownloads {
    /// Save-panel default directory.
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Strip path separators / blank → safe save-panel filename.
    public static func sanitizedFilename(_ name: String) -> String {
        let stripped = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }
}

// MARK: - Popup model

/// SSO popup (window.open/_blank): the coordinator builds the WKWebView,
/// the store publishes it, the window shows it as a modal sheet.
/// `webView == nil` only in unit tests (state transitions, no live view).
public final class TeamsFramePopup: ObservableObject, Identifiable {
    public let id = UUID()
    public let webView: WKWebView?
    public let url: URL?

    public init(webView: WKWebView? = nil, url: URL? = nil) {
        self.webView = webView
        self.url = url
    }
}

// MARK: - Lifecycle store

/// Owns the dedicated WKProcessPool + data store + registry selection.
/// destroy() nils pool+store (dedicated pool orphans its web processes).
///
/// CPU/RAM posture (owner directive, aggressive):
/// - Lazy init: pool/store/webview exist only after the surface appears
///   (activate on window appear). Fresh store holds NO web objects.
/// - NO process prewarm at app launch — deliberate: the frame costs zero
///   until opened. (Prewarm would trade launch latency for idle footprint;
///   the frame is a cold-start surface, so we keep it cold.)
/// - Hide (deactivate): stopLoading + drop script message handlers so a
///   hidden frame burns no CPU; keep-alive timer still honored.
/// - Destroy: logs the resident-MB footprint line, then nils everything.
/// - No polling while hidden: the ONLY Timer is the one-shot keep-alive
///   (repeats:false); no Task.sleep anywhere in this file.
/// Test seams: injectable UserDefaults, keepAliveArmed/suspended readback.
@MainActor
public final class TeamsFrameStore: ObservableObject {
    @Published public var alive = true
    // Published: activate() runs in onAppear (after first body eval) —
    // the publishes re-evaluate the body and create the webview.
    @Published public private(set) var pool: WKProcessPool?
    @Published public private(set) var dataStore: WKWebsiteDataStore?
    @Published public var apps: [TeamsFrameApp]
    @Published public var selectedAppID: String?
    /// Catalog URL entry override (session-only, not persisted): when set,
    /// the frame loads it instead of the selected app's entity link.
    @Published public var customURLString: String?
    @Published public var calibrationCrop = TeamsFrameCrop.v0
    @Published public var popup: TeamsFramePopup?
    public private(set) var keepAliveArmed = false
    public private(set) var suspended = false
    /// Weak: set by the representable on creation; used for hide-suspend.
    public weak var activeWebView: WKWebView?
    private var timer: Timer?
    private var launchURLApplied = false
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apps = TeamsFrameRegistry.loadApps(defaults: defaults)
        self.selectedAppID = TeamsFrameRegistry.loadSelectedID(defaults: defaults)
        // Clamp a stale persisted selection to the first app.
        if let id = selectedAppID, !apps.contains(where: { $0.id == id }) {
            selectedAppID = nil
        }
    }

    public var keepAliveMinutes: Int {
        TeamsFrameConfig.keepAliveMinutes(defaults: defaults)
    }

    public var selectedApp: TeamsFrameApp? {
        if let id = selectedAppID, let app = apps.first(where: { $0.id == id }) {
            return app
        }
        return apps.first
    }

    public var currentURLString: String {
        if let custom = customURLString, !custom.isEmpty { return custom }
        return selectedApp?.entityURL ?? TeamsFrameConfig.defaultURL
    }

    public var currentCrop: TeamsFrameCrop {
        if customURLString != nil { return .v0 }
        return selectedApp?.effectiveCrop ?? .v0
    }

    /// Switcher pick: persist selection, clear any custom URL override.
    /// The SAME webview navigates (updateNSView) — session kept, no re-auth.
    public func selectApp(id: String?) {
        selectedAppID = id
        customURLString = nil
        TeamsFrameRegistry.saveSelectedID(id, defaults: defaults)
        if let app = selectedApp {
            print("[teams-frame] app selected: \(app.label)")
        }
    }

    /// Catalog URL entry: validate lightly, load in the SAME frame.
    public func loadCustomURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            print("[teams-frame] BAD CUSTOM URL: \(raw)")
            return
        }
        customURLString = trimmed
        print("[teams-frame] custom URL loaded in frame: \(trimmed)")
    }

    /// Surface entry: (re)build the pool + store, cancel pending destroy.
    /// The CLI launch URL applies once (first appear); later appears keep
    /// the user's switcher pick.
    public func activate(launchURL: String? = nil) {
        timer?.invalidate()
        timer = nil
        keepAliveArmed = false
        suspended = false
        if !launchURLApplied {
            launchURLApplied = true
            if let launch = launchURL, launch != TeamsFrameConfig.defaultURL {
                customURLString = launch
            }
        }
        if pool == nil { pool = WKProcessPool() }
        if dataStore == nil {
            dataStore = WKWebsiteDataStore(
                forIdentifier: TeamsFrameConfig.dataStoreIdentifier)
        }
        if !alive { alive = true }
        print("[teams-frame] activate (keepAlive \(keepAliveMinutes) min)")
    }

    /// Surface exit: suspend the hidden webview now, then destroy now (0)
    /// or arm the keep-alive timer.
    public func deactivate() {
        suspended = true
        activeWebView?.stopLoading()
        activeWebView?.configuration.userContentController.removeAllScriptMessageHandlers()
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

    /// Instant destroy: log the footprint, nil the view inputs; the
    /// dedicated pool orphans its processes. Menu "Kill App Frame" lands here.
    public func destroy() {
        if let mb = TeamsFrameFootprint.residentMB() {
            print(String(format: "[teams-frame] footprint before destroy: %.1f MB resident", mb))
        } else {
            print("[teams-frame] footprint before destroy: unknown")
        }
        timer?.invalidate()
        timer = nil
        keepAliveArmed = false
        suspended = false
        activeWebView = nil
        pool = nil
        dataStore = nil
        popup = nil
        alive = false
        print("[teams-frame] DESTROYED (pool orphaned)")
    }

    public func presentPopup(_ popup: TeamsFramePopup) {
        self.popup = popup
        print("[teams-frame] popup presented: \(popup.url?.absoluteString ?? "?")")
    }

    public func closePopup() {
        popup = nil
        print("[teams-frame] popup closed")
    }
}

// MARK: - Webview (NSViewRepresentable)

/// Teams webview: dedicated process pool + own persistent data store.
/// Escapes: non-allowlisted TOP-LEVEL nav is yanked (cancel + native
/// Open-in-Browser alert); subframes log + allow. SSO popups
/// (window.open/_blank) open in a modal sheet; JS alert/confirm/prompt
/// get native panels; non-renderable responses get a save panel.
public struct TeamsFrameWebView: NSViewRepresentable {
    public let urlString: String
    public let pool: WKProcessPool
    public let dataStore: WKWebsiteDataStore
    public let store: TeamsFrameStore

    public init(urlString: String, pool: WKProcessPool, dataStore: WKWebsiteDataStore, store: TeamsFrameStore) {
        self.urlString = urlString
        self.pool = pool
        self.dataStore = dataStore
        self.store = store
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = pool
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = TeamsFrameConfig.userAgentSuffix
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.store = store
        context.coordinator.lastLoadedURLString = urlString
        let storeRef = store
        Task { @MainActor in storeRef.activeWebView = view }
        if let url = URL(string: urlString) {
            print("[teams-frame] webview created, loading \(urlString)")
            view.load(URLRequest(url: url))
        } else {
            print("[teams-frame] BAD URL STRING: \(urlString)")
        }
        return view
    }

    public func updateNSView(_ view: WKWebView, context: Context) {
        // Switcher: the selection/catalog URL changed → navigate the SAME
        // webview (same pool + store → session kept, no re-auth).
        // Compared against what WE asked to load (not view.url, which
        // moves under SPA routing) so in-page nav never double-loads.
        if context.coordinator.lastLoadedURLString != urlString,
           let url = URL(string: urlString)
        {
            context.coordinator.lastLoadedURLString = urlString
            print("[teams-frame] switching frame to \(urlString)")
            view.load(URLRequest(url: url))
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        public weak var store: TeamsFrameStore?
        public var lastLoadedURLString: String?

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
                switch TeamsFrameConfig.escapeDecision(url: url, isMainFrame: mainFrame) {
                case .allow:
                    break
                case .allowLogged:
                    print("[teams-frame] ESCAPE (allowed, subframe): \(url.absoluteString)")
                case .yank:
                    print("[teams-frame] ESCAPE (yanked, top-level): \(url.absoluteString)")
                    decisionHandler(.cancel)
                    Task { @MainActor in Self.offerExternalOpen(url: url) }
                    return
                }
            }
            decisionHandler(.allow)
        }

        /// Yank follow-up: native alert offering Open-in-Browser.
        /// Runs after .cancel so the modal never blocks the webview.
        @MainActor
        private static func offerExternalOpen(url: URL) {
            let alert = NSAlert()
            alert.messageText = "Open in Browser?"
            alert.informativeText = "This link leaves Teams:\n\(url.absoluteString)"
            alert.addButton(withTitle: "Open in Browser")
            alert.addButton(withTitle: "Stay Here")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[teams-frame] started: \(webView.url?.absoluteString ?? "?")")
        }

        // Load readback (proves the frame fetched).
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

        // MARK: Downloads — non-renderable top-level responses.

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                print("[teams-frame] DOWNLOAD: \(navigationResponse.response.url?.absoluteString ?? "?")")
                decisionHandler(.download)
            }
        }

        public func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        public func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let panel = NSSavePanel()
            panel.directoryURL = TeamsFrameDownloads.defaultDirectory()
            panel.nameFieldStringValue = TeamsFrameDownloads.sanitizedFilename(suggestedFilename)
            guard panel.runModal() == .OK, let url = panel.url else {
                print("[teams-frame] download cancelled: \(suggestedFilename)")
                completionHandler(nil)
                return
            }
            print("[teams-frame] download → \(url.path)")
            completionHandler(url)
        }

        // MARK: WKUIDelegate — SSO popups + JS panels.

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard TeamsFrameConfig.interceptsPopup(
                targetFrameIsNil: navigationAction.targetFrame == nil)
            else { return nil }
            let popupView = WKWebView(frame: .zero, configuration: configuration)
            popupView.navigationDelegate = self
            popupView.uiDelegate = self
            let url = navigationAction.request.url
            if let url {
                popupView.load(URLRequest(url: url))
            }
            print("[teams-frame] POPUP: \(url?.absoluteString ?? "?")")
            let popup = TeamsFramePopup(webView: popupView, url: url)
            let store = self.store
            Task { @MainActor in store?.presentPopup(popup) }
            return popupView
        }

        public func webViewDidClose(_ webView: WKWebView) {
            let store = self.store
            Task { @MainActor in store?.closePopup() }
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = "Teams App"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = "Teams App"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = "Teams App"
            alert.informativeText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                completionHandler(field.stringValue)
            } else {
                completionHandler(nil)
            }
        }
    }
}

// MARK: - Window content

/// Frame window: switcher bar + cropped webview while `store.alive`,
/// placeholder after destroy (Reopen rebuilds via activate — no relaunch).
public struct TeamsFrameWindow: View {
    @ObservedObject public var store: TeamsFrameStore
    public let launchURL: String
    public let fullFrame: Bool
    public let calibrate: Bool
    @State private var urlField = ""

    public init(store: TeamsFrameStore, launchURL: String, fullFrame: Bool, calibrate: Bool = false) {
        self.store = store
        self.launchURL = launchURL
        self.fullFrame = fullFrame
        self.calibrate = calibrate
    }

    private var effectiveCrop: TeamsFrameCrop {
        if fullFrame { return .none }
        if calibrate { return store.calibrationCrop }
        return store.currentCrop
    }

    public var body: some View {
        let crop = effectiveCrop
        VStack(spacing: 0) {
            // Switcher: native menu Picker (SwiftUI Picker +
            // .pickerStyle(.menu), AppKit NSPopUpButton under the hood)
            // + catalog URL entry. Both load in the SAME frame.
            HStack(spacing: 8) {
                Picker(
                    "App",
                    selection: Binding(
                        get: { store.selectedAppID ?? store.selectedApp?.id },
                        set: { store.selectApp(id: $0) }
                    )
                ) {
                    ForEach(store.apps) { app in
                        Text(app.label).tag(app.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .labelsHidden()
                TextField("Entity deep link…", text: $urlField, onCommit: {
                    store.loadCustomURL(urlField)
                })
                .textFieldStyle(.roundedBorder)
                Button("Load") { store.loadCustomURL(urlField) }
            }
            .padding(8)
            Divider()
            Group {
                if store.alive, let pool = store.pool, let dataStore = store.dataStore {
                    if TeamsFrameConfig.isPlaceholderURL(store.currentURLString) {
                        TeamsFramePlaceholderView()
                    } else {
                        ZStack {
                            GeometryReader { geo in
                                TeamsFrameWebView(
                                    urlString: store.currentURLString,
                                    pool: pool,
                                    dataStore: dataStore,
                                    store: store
                                )
                                .frame(
                                    width: geo.size.width + crop.left,
                                    height: geo.size.height + crop.top)
                                .offset(x: -crop.left, y: -crop.top)
                            }
                            .clipped()
                            if calibrate {
                                TeamsFrameCalibrateOverlay(crop: $store.calibrationCrop)
                            }
                        }
                    }
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
        }
        .onAppear { store.activate(launchURL: launchURL) }
        .onDisappear { store.deactivate() }
        .onReceive(NotificationCenter.default.publisher(for: .killTeamsFrame)) { _ in
            store.destroy()
        }
        .sheet(item: $store.popup) { popup in
            TeamsFramePopupSheet(popup: popup, onClose: { store.closePopup() })
        }
    }
}

// MARK: - Placeholder guidance (unexpanded seed URL)

/// Shown instead of the webview while the current URL is an unexpanded
/// `<…>` placeholder (seed state): no webview is created, nothing loads.
public struct TeamsFramePlaceholderView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No app configured")
                .font(.headline)
            Text("Pick an app in the switcher, or paste a Teams entity deep link above and press Load.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Popup sheet (SSO window.open/_blank)

public struct TeamsFramePopupSheet: View {
    public let popup: TeamsFramePopup
    public let onClose: () -> Void

    public init(popup: TeamsFramePopup, onClose: @escaping () -> Void) {
        self.popup = popup
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(popup.url?.host ?? "Sign-in")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let view = popup.webView {
                TeamsFramePopupWebView(webView: view)
            } else {
                Text("Loading…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 600)
    }
}

/// Thin wrapper around the coordinator-built popup webview.
public struct TeamsFramePopupWebView: NSViewRepresentable {
    public let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func makeNSView(context: Context) -> WKWebView { webView }
    public func updateNSView(_ view: WKWebView, context: Context) {}
}

// MARK: - Crop calibration overlay (debug aid)

/// --teams-frame-calibrate: draggable red guides over the frame + live
/// inset readback. Owner drags post-login; values print on each release.
/// The overlay passes clicks through except on the guides/label.
public struct TeamsFrameCalibrateOverlay: View {
    @Binding public var crop: TeamsFrameCrop

    public init(crop: Binding<TeamsFrameCrop>) {
        self._crop = crop
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Left guide: 14pt grab strip, 2pt visible line.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 14)
                    .overlay(
                        Rectangle().fill(Color.red.opacity(0.8)).frame(width: 2)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(x: crop.left - 7)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                crop.left = max(0, min(value.location.x, geo.size.width))
                            }
                            .onEnded { _ in
                                print("[teams-frame] calibrate: left=\(Int(crop.left)) top=\(Int(crop.top))")
                            }
                    )
                // Top guide: 14pt grab strip, 2pt visible line.
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 14)
                    .overlay(
                        Rectangle().fill(Color.red.opacity(0.8)).frame(height: 2)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(y: crop.top - 7)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                crop.top = max(0, min(value.location.y, geo.size.height))
                            }
                            .onEnded { _ in
                                print("[teams-frame] calibrate: left=\(Int(crop.left)) top=\(Int(crop.top))")
                            }
                    )
                VStack {
                    HStack {
                        Spacer()
                        Text("left \(Int(crop.left)) · top \(Int(crop.top))")
                            .font(.caption)
                            .monospacedDigit()
                            .padding(6)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
        .onAppear {
            print("[teams-frame] calibrate overlay on (drag guides; values print on release)")
        }
    }
}
