// OstMacAuth — om-authux lane shell: sign-in view, live or canned.
// Usage:
//   OstMacAuth --state <name>   canned state, never touches core/network
//                               (names: signed-out, starting, code, polling,
//                               signed-in, expired, refreshing,
//                               refresh-failed, error)
//   OstMacAuth                   live: real status + device-code flow
//                                (status check is read-only; sign-in opens
//                                the user's browser, no automation)
import OstMacCore
import SwiftUI

@main
struct AuthApp: App {
    @StateObject private var model: AuthViewModel
    private let isLive: Bool

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--state"), i + 1 < args.count {
            _model = StateObject(wrappedValue: .demo(Self.state(named: args[i + 1])))
            isLive = false
        } else {
            _model = StateObject(wrappedValue: AuthViewModel())
            isLive = true
        }
    }

    static func state(named: String) -> AuthState {
        switch named {
        case "signed-out": .signedOut
        case "starting": .starting
        case "code": .code(.demo)
        case "polling": .polling(.demo, attempts: 2)
        case "signed-in": .signedIn
        case "expired": .expired
        case "refreshing": .refreshing
        case "refresh-failed": .refreshFailed("refresh: token request failed (demo)")
        case "error": .error("device_start: network unreachable (demo)")
        default: .signedOut
        }
    }

    var body: some Scene {
        WindowGroup("OstMac Auth") {
            AuthView(model: model)
                .task {
                    if isLive { await model.refreshStatus() }
                }
        }
        .defaultSize(width: 440, height: 520)
    }
}
