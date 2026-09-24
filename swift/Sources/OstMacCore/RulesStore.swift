// RulesStore.swift — om-notif-settings lane: observable rules config.
//
// Single source of truth for RulesConfig in the app: loads rules.json
// once, publishes the config, and persists every mute/unmute and
// hide/unhide immediately (best-effort save — a failed write keeps the
// in-memory value for the session). AppState reads `config` for its
// per-event rules decisions; Settings binds the per-chat override list
// here and the sidebar the mute/hide context menu.
import Combine
import Foundation

/// Observable RulesConfig: load once, mutate + persist per change.
@MainActor
public final class RulesStore: ObservableObject {
    /// Current config (per-chat mutes included). Published: Settings
    /// rows and AppState decisions read this same value.
    @Published public private(set) var config: RulesConfig

    /// rules.json path (default store location; tests inject a temp path).
    public let path: String

    /// Load best-effort: a missing or unreadable file yields `.default`
    /// (same fallback as RulesConfig.loadBestEffort).
    ///
    /// Nonisolated so views can take a default `RulesStore()` in their
    /// (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(path: String = RulesConfig.defaultPath) {
        let expanded = NSString(string: path).expandingTildeInPath
        self.path = expanded
        _config = Published(initialValue: RulesConfig.loadBestEffort(from: expanded))
    }

    /// True when the chat is muted in Settings (skipped as "chat-muted").
    public func isMuted(chatID: String) -> Bool {
        config.mutedChatIDs.contains(chatID)
    }

    /// Mute or unmute one chat, persisting immediately. No-ops (same
    /// value) skip the write.
    public func setMuted(chatID: String, muted: Bool) {
        guard !chatID.isEmpty, config.mutedChatIDs.contains(chatID) != muted else { return }
        if muted {
            config.mutedChatIDs.insert(chatID)
        } else {
            config.mutedChatIDs.remove(chatID)
        }
        try? config.save(to: path)
    }

    /// True when the chat is hidden from the sidebar list.
    public func isHidden(chatID: String) -> Bool {
        config.hiddenChatIDs.contains(chatID)
    }

    /// Hide or unhide one chat, persisting immediately. No-ops (same
    /// value) skip the write. Visibility only — banners and unread are
    /// untouched (see RulesConfig.hiddenChatIDs).
    public func setHidden(chatID: String, hidden: Bool) {
        guard !chatID.isEmpty, config.hiddenChatIDs.contains(chatID) != hidden else { return }
        if hidden {
            config.hiddenChatIDs.insert(chatID)
        } else {
            config.hiddenChatIDs.remove(chatID)
        }
        try? config.save(to: path)
    }
}
