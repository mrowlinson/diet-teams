// SettingsRouting.swift — om-settings-org lane: which Settings the
// scene shows. Demo launches (and the keywords shot) get the fixed
// sanitized view — they must never embed the LIVE AuthViewModel, or a
// demo screenshot/settings walk leaks the owner's live identity.
//
// Pure + tested; the App scene calls `useIsolatedDemo`, the view
// layer consumes `isolatedDemoAccount`.
import Foundation

public enum SettingsRouting {
    /// True when Settings must isolate from live auth: every demo
    /// launch, plus the sanitized keywords/attention shot hooks.
    public static func useIsolatedDemo(isDemo: Bool, args: [String]) -> Bool {
        isDemo || args.contains("--show-settings-keywords")
            || args.contains("--show-settings-attention")
    }

    /// Sanitized account row for isolated Settings (never live state).
    public static let isolatedDemoAccount = AccountInfo(
        signedIn: false, detail: "Signed out (demo)")

    /// Preselected sidebar category (shot hooks only; real launches
    /// always open on Account).
    public static func initialCategory(args: [String]) -> SettingsCategory {
        if args.contains("--show-settings-calls") { return .calls }
        if args.contains("--show-settings-summaries") { return .summaries }
        if args.contains("--show-settings-keywords") { return .notifications }
        if args.contains("--show-settings-attention") { return .notifications }
        return .account
    }
}

/// Sidebar categories for the Settings scene (macOS 14 native idiom:
/// NavigationSplitView with a sidebar list + detail forms).
public enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case account
    case notifications
    case chats
    case calls
    case summaries
    case gifs
    case advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .account: "Account"
        case .notifications: "Notifications"
        case .chats: "Chats"
        case .calls: "Calls"
        case .summaries: "Summaries"
        case .gifs: "GIFs"
        case .advanced: "Advanced"
        }
    }

    public var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .notifications: "bell"
        case .chats: "bubble.left.and.bubble.right"
        case .calls: "phone"
        case .summaries: "sparkles"
        case .gifs: "photo"
        case .advanced: "gearshape"
        }
    }
}
