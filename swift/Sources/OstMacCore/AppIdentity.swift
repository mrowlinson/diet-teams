// AppIdentity.swift — om-app-union: single source for app branding.
// Moved from the om-package OstMacApp module (deleted in the union);
// About window, Settings, entry, and tests all read these.
// Info.plist (OstMac-Info.plist) mirrors them.
import Foundation

public enum AppIdentity {
    public static let name = "OstMac"
    public static let bundleID = "dev.ostmac.OstMac"
    public static let version = "0.1.0"
    public static let minimumOS = "14.0"
    public static let aboutWindowID = "about"
    public static let authWindowID = "auth"
    public static let tagline = "Teams client for macOS"
}

// MARK: - Account (Settings window, read-only)

/// Read-only account snapshot for the Settings window.
public struct AccountInfo: Equatable, Sendable {
    public let signedIn: Bool
    public let detail: String

    public init(signedIn: Bool, detail: String) {
        self.signedIn = signedIn
        self.detail = detail
    }

    public static let loading = AccountInfo(signedIn: false, detail: "Loading…")
    public static let unavailable = AccountInfo(signedIn: false, detail: "Status unavailable")

    /// Deterministic one-line summary of a core status response.
    public static func summarize(_ status: StatusResponse) -> AccountInfo {
        guard status.signed_in else {
            return AccountInfo(signedIn: false, detail: "Not signed in")
        }
        let slots = [
            status.tokens.aad.present,
            status.tokens.refresh_present,
            status.tokens.graph.present,
            status.tokens.ic3.present,
            status.tokens.recorder.present,
            status.tokens.skype.present,
            status.tokens.region_gtms_present,
        ]
        let n = slots.filter { $0 }.count
        return AccountInfo(signedIn: true, detail: "Signed in · tokens \(n)/\(slots.count)")
    }
}
