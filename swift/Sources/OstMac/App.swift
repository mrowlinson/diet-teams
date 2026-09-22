// OstMac — om-package lane: real app entry. Main window (chats +
// conversation), About window, Settings shell. Quit is automatic.
// Usage: OstMac [--demo] [--show-about]
import OstMacApp
import SwiftUI

@main
struct OstMacAppMain: App {
    private let demo = CommandLine.arguments.contains("--demo")

    var body: some Scene {
        WindowGroup("OstMac") {
            OstMacRootView(demo: demo)
        }
        .defaultSize(width: 960, height: 620)
        Window("About OstMac", id: AppIdentity.aboutWindowID) {
            AboutView()
        }
        .defaultSize(width: 360, height: 340)
        .windowResizability(.contentSize)
        Settings {
            SettingsView()
        }
        .commands { OstMacCommands() }
    }
}

/// App menu: About opens our About window (standard panel replaced);
/// Settings… (from the Settings scene) and Quit stay automatic.
private struct OstMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About OstMac") { openWindow(id: AppIdentity.aboutWindowID) }
        }
    }
}
