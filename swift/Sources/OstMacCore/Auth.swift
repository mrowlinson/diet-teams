// Auth.swift — om-authux lane: device-code sign-in state machine.
//
// Happy path: signedOut -> starting -> code -> polling -> signedIn.
// The persisted session (tokens on disk) is reused across launches:
// refreshStatus() on appear lands on signedIn without any network.
// Expiry path: signedIn -> expired -> refreshing -> signedIn | refreshFailed.
// Browser fallback (om-pwauth): signedOut/expired/error -> starting ->
// browser -> browserWorking -> signedIn (MFA/SSO tenants where the
// device-code flow fails).
// Any failure -> error, with retry() re-entering the matching step.
//
// All core calls are injected (default = live RustCore) so tests drive the
// full machine without network, browser, or pasteboard.
import AppKit
import Combine
import Foundation

/// Device-code session info from the core's device_start.
public struct AuthCodeInfo: Equatable, Sendable {
    public let session: String
    public let verificationURI: String
    public let userCode: String
    public let message: String
    public let expiresIn: Int
    public let interval: Int

    public init(
        session: String, verificationURI: String, userCode: String,
        message: String, expiresIn: Int, interval: Int
    ) {
        self.session = session
        self.verificationURI = verificationURI
        self.userCode = userCode
        self.message = message
        self.expiresIn = expiresIn
        self.interval = interval
    }

    public init(_ d: DeviceStart) {
        self.init(
            session: d.session, verificationURI: d.verification_uri,
            userCode: d.user_code, message: d.message,
            expiresIn: d.expires_in, interval: d.interval)
    }

    /// Canned info for demo states (screenshots) and previews. Never core.
    public static let demo = AuthCodeInfo(
        session: "dc-demo-1",
        verificationURI: "https://microsoft.com/devicelogin",
        userCode: "ABCD-1234",
        message: "To sign in, use a web browser to open the page and enter the code.",
        expiresIn: 900, interval: 5)
}

/// Browser-capture session info from the core's authcode_start.
public struct AuthBrowserInfo: Equatable, Sendable {
    public let session: String
    public let authorizeURL: String
    public let redirectURI: String

    public init(session: String, authorizeURL: String, redirectURI: String) {
        self.session = session
        self.authorizeURL = authorizeURL
        self.redirectURI = redirectURI
    }

    public init(_ d: AuthCodeStart) {
        self.init(
            session: d.session, authorizeURL: d.authorize_url,
            redirectURI: d.redirect_uri)
    }

    /// Canned info for demo states (screenshots) and previews. Never core.
    /// The authorize URL is fake: the demo webview never loads it.
    public static let demo = AuthBrowserInfo(
        session: "ba-demo-1",
        authorizeURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?demo=1",
        redirectURI: "https://login.microsoftonline.com/common/oauth2/nativeclient")
}

/// Every sign-in UI state. `polling` carries the attempt count for the view.
public enum AuthState: Equatable, Sendable {
    case unknown
    case signedOut
    case starting
    case code(AuthCodeInfo)
    case polling(AuthCodeInfo, attempts: Int)
    case browser(AuthBrowserInfo)
    case browserWorking(AuthBrowserInfo)
    case signedIn
    case signingOut
    case expired
    case refreshing
    case refreshFailed(String)
    case error(String)
}

extension AuthState {
    /// True only for signedIn. The main-window gate, the feed/chats
    /// sequencing, and Settings all key off this (single source).
    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    /// Main-window content gate. Demo mode bypasses (caller-side).
    public var allowsContent: Bool { isSignedIn }
}

/// Where error(_)'s "Try again" re-enters. (Refresh failures surface as
/// refreshFailed with their own retry button, never as error.)
public enum AuthRetry: Equatable, Sendable {
    case signIn
    case status
    case signOut
    case browser
}

@MainActor
public final class AuthViewModel: ObservableObject {
    public typealias StatusFn = @Sendable () throws -> StatusResponse
    public typealias StartFn = @Sendable () throws -> DeviceStart
    public typealias PollFn = @Sendable (String) throws -> DevicePoll
    public typealias RefreshFn = @Sendable () throws -> RefreshResponse
    public typealias SignOutFn = @Sendable () throws -> SignOutResponse
    public typealias OpenURLFn = @Sendable (URL) -> Bool
    public typealias CopyFn = @Sendable (String) -> Void
    public typealias BrowserStartFn = @Sendable () throws -> AuthCodeStart
    public typealias BrowserCompleteFn = @Sendable (String, String) throws -> AuthCodeComplete
    public typealias BrowserCancelFn = @Sendable (String) throws -> AuthCodeCancel

    @Published public private(set) var state: AuthState = .unknown
    @Published public private(set) var copied = false
    @Published public private(set) var status: StatusResponse?
    public private(set) var isDemo = false
    /// Where error(_)'s retry goes. Updated on every failure.
    public private(set) var errorRetry: AuthRetry = .signIn
    /// Gate mirror of state (single source; AppState subscribes to $state).
    public var isSignedIn: Bool { state.isSignedIn }
    /// Overrides the core's poll interval (tests set 3600 + drive pollOnce).
    public var pollIntervalOverride: TimeInterval?

    private let statusFn: StatusFn
    private let startFn: StartFn
    private let pollFn: PollFn
    private let refreshFn: RefreshFn
    private let signOutFn: SignOutFn
    private let openURLFn: OpenURLFn
    private let copyFn: CopyFn
    private let browserStartFn: BrowserStartFn
    private let browserCompleteFn: BrowserCompleteFn
    private let browserCancelFn: BrowserCancelFn
    private var pollTask: Task<Void, Never>?
    private var stateBeforeSignIn: AuthState?

    public init(
        status: @escaping StatusFn = { try RustCore.status() },
        start: @escaping StartFn = { try RustCore.deviceStart() },
        poll: @escaping PollFn = { try RustCore.devicePoll(session: $0) },
        refresh: @escaping RefreshFn = { try RustCore.refresh() },
        signOut: @escaping SignOutFn = { try RustCore.signOut() },
        openURL: @escaping OpenURLFn = { NSWorkspace.shared.open($0) },
        copy: @escaping CopyFn = { code in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        },
        browserStart: @escaping BrowserStartFn = { try RustCore.browserStart() },
        browserComplete: @escaping BrowserCompleteFn = {
            try RustCore.browserComplete(session: $0, callback: $1)
        },
        browserCancel: @escaping BrowserCancelFn = {
            try RustCore.browserCancel(session: $0)
        }
    ) {
        self.statusFn = status
        self.startFn = start
        self.pollFn = poll
        self.refreshFn = refresh
        self.signOutFn = signOut
        self.openURLFn = openURL
        self.copyFn = copy
        self.browserStartFn = browserStart
        self.browserCompleteFn = browserComplete
        self.browserCancelFn = browserCancel
    }

    /// Read-only status check (no network): reuses the persisted session.
    public func refreshStatus() async {
        if isDemo { return }
        let fn = statusFn
        do {
            let st = try await Task.detached { try fn() }.value
            status = st
            state = Self.classify(st)
        } catch {
            errorRetry = .status
            state = .error(Self.message(for: error))
        }
    }

    public static func classify(_ st: StatusResponse) -> AuthState {
        if st.signed_in { return .signedIn }
        if st.tokens.aad.present, st.tokens.aad.expired { return .expired }
        return .signedOut
    }

    /// Begin device-code flow: starting -> code | error.
    public func signIn() async {
        if isDemo { return }
        switch state {
        case .starting, .code, .polling, .browser, .browserWorking,
             .refreshing, .signingOut: return
        default: break
        }
        stopPolling()
        stateBeforeSignIn = state
        state = .starting
        copied = false
        let fn = startFn
        do {
            let d = try await Task.detached { try fn() }.value
            state = .code(AuthCodeInfo(d))
        } catch {
            errorRetry = .signIn
            state = .error(Self.message(for: error))
        }
    }

    /// Open the verification page in the browser and start polling.
    /// No-op outside code/polling (polling re-opens without resetting).
    public func openBrowser() {
        if isDemo { return }
        switch state {
        case let .code(info):
            open(info.verificationURI)
            startPolling(info)
        case let .polling(info, _):
            open(info.verificationURI)
        default: break
        }
    }

    /// Start polling without opening the browser (user opened it manually).
    public func startChecking() {
        if isDemo { return }
        guard case let .code(info) = state else { return }
        startPolling(info)
    }

    public func copyCode() {
        let code: String? = switch state {
        case let .code(info): info.userCode
        case let .polling(info, _): info.userCode
        default: nil
        }
        guard let code else { return }
        copyFn(code)
        copied = true
    }

    /// Single poll step. The loop calls it; tests call it directly.
    /// pending -> polling(+1); complete -> refreshStatus; fatal -> error.
    public func pollOnce() async {
        if isDemo { return }
        guard case let .polling(info, attempts) = state else { return }
        let fn = pollFn
        do {
            let p = try await Task.detached { try fn(info.session) }.value
            if p.status == "complete" {
                stopPolling()
                await refreshStatus()
            } else {
                state = .polling(info, attempts: attempts + 1)
            }
        } catch {
            stopPolling()
            errorRetry = .signIn
            state = .error(Self.message(for: error))
        }
    }

    /// Leave code/polling, back to wherever sign-in started.
    public func cancel() {
        stopPolling()
        copied = false
        state = stateBeforeSignIn ?? .signedOut
        stateBeforeSignIn = nil
    }

    /// Retry a token refresh from expired/refreshFailed/error.
    public func retryRefresh() async {
        if isDemo { return }
        switch state {
        case .expired, .refreshFailed, .error: break
        default: return
        }
        state = .refreshing
        let fn = refreshFn
        do {
            let r = try await Task.detached { try fn() }.value
            if r.refreshed {
                await refreshStatus()
            } else {
                state = .refreshFailed("No refresh token stored. Sign in again.")
            }
        } catch {
            state = .refreshFailed(Self.message(for: error))
        }
    }

    public func signOut() async {
        if isDemo { return }
        guard state != .signingOut else { return }
        stopPolling()
        state = .signingOut
        let fn = signOutFn
        do {
            _ = try await Task.detached { try fn() }.value
            status = nil
            state = .signedOut
        } catch {
            errorRetry = .signOut
            state = .error(Self.message(for: error))
        }
    }

    /// error(_)'s "Try again": re-enter the step that failed.
    public func retry() async {
        switch errorRetry {
        case .signIn: await signIn()
        case .status: await refreshStatus()
        case .signOut: await signOut()
        case .browser: await startBrowserSignIn()
        }
    }

    // MARK: - Browser-capture fallback (om-pwauth)

    /// Begin browser-capture flow: starting -> browser | error.
    /// Entry from signedOut/expired/refreshFailed/error (never from inside
    /// the device flow: cancel that first). From error the pre-failure
    /// origin is kept so cancel skips the error screen.
    public func startBrowserSignIn() async {
        if isDemo { return }
        switch state {
        case .starting, .code, .polling, .browser, .browserWorking,
             .refreshing, .signingOut: return
        default: break
        }
        stopPolling()
        if case .error = state {
            if stateBeforeSignIn == nil { stateBeforeSignIn = .signedOut }
        } else {
            stateBeforeSignIn = state
        }
        state = .starting
        let fn = browserStartFn
        do {
            let d = try await Task.detached { try fn() }.value
            state = .browser(AuthBrowserInfo(d))
        } catch {
            errorRetry = .browser
            state = .error(Self.message(for: error))
        }
    }

    /// Finish browser-capture with the intercepted callback URL:
    /// browser -> browserWorking -> refreshStatus | error.
    /// No-op outside .browser (double-redirects, late callbacks).
    public func completeBrowserSignIn(callbackURL: String) async {
        if isDemo { return }
        guard case let .browser(info) = state else { return }
        state = .browserWorking(info)
        let fn = browserCompleteFn
        do {
            let r = try await Task.detached { try fn(info.session, callbackURL) }.value
            if r.status == "complete" {
                await refreshStatus()
            } else {
                errorRetry = .browser
                state = .error("browser sign-in returned \(r.status)")
            }
        } catch {
            errorRetry = .browser
            state = .error(Self.message(for: error))
        }
    }

    /// Leave browser/browserWorking: drop the core session (best-effort),
    /// back to wherever sign-in started.
    public func cancelBrowser() {
        switch state {
        case let .browser(info), let .browserWorking(info):
            let fn = browserCancelFn
            let session = info.session
            Task.detached { _ = try? fn(session) }
            state = stateBeforeSignIn ?? .signedOut
            stateBeforeSignIn = nil
        default: break
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        _ = openURLFn(url)
    }

    private func startPolling(_ info: AuthCodeInfo) {
        stopPolling()
        state = .polling(info, attempts: 0)
        let delay = pollIntervalOverride ?? TimeInterval(max(info.interval, 5))
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }
                await self.pollOnce()
                if case .polling = self.state { continue }
                break
            }
        }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }

    // MARK: - Demo (canned states for screenshots; never touches core)

    public static func demo(_ state: AuthState) -> AuthViewModel {
        let vm = AuthViewModel(
            status: { throw CoreCallError.failed("demo") },
            start: { throw CoreCallError.failed("demo") },
            poll: { _ in throw CoreCallError.failed("demo") },
            refresh: { throw CoreCallError.failed("demo") },
            signOut: { throw CoreCallError.failed("demo") },
            openURL: { _ in false },
            copy: { _ in },
            browserStart: { throw CoreCallError.failed("demo") },
            browserComplete: { _, _ in throw CoreCallError.failed("demo") },
            browserCancel: { _ in throw CoreCallError.failed("demo") })
        vm.isDemo = true
        vm.state = state
        return vm
    }
}
