// QuickComposerPanel.swift — f1-composer lane: the floating composer
// panel (AppKit-level, NOT a SwiftUI scene). AppKit-owned so summon
// works while Better Teams is backgrounded AND when all its windows
// are closed (no RootView observer needed); summoning reopens ONLY
// this panel, never the main window. Content is a fresh
// QuickComposerView per summon (no stale target/draft).
import AppKit
import OstMacChatList
import OstMacCore
import SwiftUI

/// Floating utility panel hosting the quick composer. Main-thread only
/// (owned by AppState, itself @MainActor).
final class QuickComposerPanelController {
    private var panel: NSPanel?
    private var host: NSHostingController<QuickComposerView>?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show + key the panel (fresh target/message each summon; `nil`
    /// preseeds summon blank). Works from any frontmost app and with
    /// zero Better Teams windows open. No app activation: the panel
    /// keys as a palette, leaving the user's front app untouched.
    func summon(
        chats: ChatListViewModel, teams: TeamsViewModel,
        signedIn: Bool,
        initialTargetQuery: String? = nil,
        initialMessage: String? = nil,
        initialPickFirst: Bool = false,
        onSend: @escaping (String, String, String) -> Void
    ) {
        let view = QuickComposerView(
            chats: chats, teams: teams,
            signedIn: signedIn,
            initialTargetQuery: initialTargetQuery ?? "",
            initialMessage: initialMessage ?? "",
            initialPickFirst: initialPickFirst,
            onSend: { [weak self] id, name, text in
                onSend(id, name, text)
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() })
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            panel.identifier = NSUserInterfaceItemIdentifier(AppIdentity.quickComposerPanelID)
            panel.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: view)
            panel.contentViewController = host
            self.host = host
            self.panel = panel
        } else {
            host?.rootView = view
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Hide the panel. Touches no main-window state (selection, drafts,
    /// scroll all live in AppState/stores, never in this controller).
    func dismiss() {
        panel?.orderOut(nil)
    }
}
