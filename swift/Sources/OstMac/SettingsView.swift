// SettingsView.swift — om-settings-trim lane: essentials only, native Form.
//
// Kept (every row wired to real behavior): Account status (gate
// one-liner), Sign in (shared AuthViewModel), Notifications (banner,
// preview and sound toggles, persisted), Per-chat overrides (mute
// toggles per chat, persisted in rules.json and enforced by the
// rules engine), GIFs Tenor key (picker reads the same key),
// Thread catch-up (CatchUpStore; Base URL hides when the CLI provider
// ignores it).
// Removed: Application (dup of About), Diagnostics (moved to the
// Diagnostics window — Window ▸ Diagnostics).
import OstMacCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var auth: AuthViewModel
    @ObservedObject private var catchUp: CatchUpStore
    @ObservedObject private var notifs: MessageNotifications
    @ObservedObject private var rules: RulesStore
    /// Roster snapshot (read-only; never triggers a chat-list refresh).
    private let chats: [ChatItem]
    @AppStorage("tenorAPIKey") private var tenorAPIKey = ""
    private let fixedAccount: AccountInfo?

    /// Live view: shares the app's models (single source of truth).
    init(
        auth: AuthViewModel,
        catchUp: CatchUpStore = CatchUpStore(),
        notifs: MessageNotifications = MessageNotifications(),
        rules: RulesStore = RulesStore(),
        chats: [ChatItem] = []
    ) {
        _auth = ObservedObject(wrappedValue: auth)
        _catchUp = ObservedObject(wrappedValue: catchUp)
        _notifs = ObservedObject(wrappedValue: notifs)
        _rules = ObservedObject(wrappedValue: rules)
        self.chats = chats
        fixedAccount = nil
    }

    /// Fixed view (previews, shots): never touches core.
    @MainActor
    init(account: AccountInfo) {
        _auth = ObservedObject(wrappedValue: .demo(.signedOut))
        _catchUp = ObservedObject(wrappedValue: CatchUpStore())
        _notifs = ObservedObject(wrappedValue: MessageNotifications())
        _rules = ObservedObject(wrappedValue: RulesStore())
        chats = []
        fixedAccount = account
    }

    public var body: some View {
        ScrollView {
            Form {
                Section("Account") {
                    LabeledContent("Status", value: account.detail)
                        .textSelection(.enabled)
                }
                if fixedAccount == nil {
                    Section("Sign in") {
                        AuthView(model: auth)
                    }
                }
                Section("Notifications") {
                    Toggle("Message banners", isOn: $notifs.enabled)
                        .help("When off, no chat banners are posted")
                    Toggle("Show message preview", isOn: $notifs.showPreview)
                        .help("When off, banners show who wrote, never the text")
                    Toggle("Play banner sound", isOn: $notifs.sound)
                        .help("When off, banners post silent")
                    LabeledContent("System permission", value: permissionText)
                }
                Section("Per-chat overrides") {
                    if chats.isEmpty, rules.config.mutedChatIDs.isEmpty {
                        Text("No chats loaded yet. Muted chats appear here once the chat list loads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(chats) { chat in
                            Toggle(chat.name, isOn: muteBinding(chat.id))
                                .help(muteHelp(chatID: chat.id))
                        }
                        ForEach(orphanedMuteIDs, id: \.self) { chatID in
                            HStack {
                                Text(chatID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Unmute") {
                                    rules.setMuted(chatID: chatID, muted: false)
                                }
                            }
                            .help("Muted, but no longer in the chat list")
                        }
                    }
                    Text("Muted chats never banner and never accrue unread (rules reason “chat-muted”).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("GIFs (Tenor)") {
                    SecureField("Tenor API key", text: $tenorAPIKey)
                    Text("Bring your own free key (Google Cloud Console → Tenor API). Empty = GIF picker stays off; nothing is sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                CatchUpSettingsSection(catchUp: catchUp)
            }
            .formStyle(.grouped)
            .padding()
        }
        // Live embeds the full AuthView (min 420 tall); fixed stays compact.
        .frame(width: 460, height: fixedAccount == nil ? 760 : nil)
        .task {
            guard fixedAccount == nil else { return }
            await auth.refreshStatus()
        }
    }

    /// Muted ids with no roster row (renamed/left chats): still
    /// enforced, listed so they can be unmuted. Sorted for stability.
    private var orphanedMuteIDs: [String] {
        let known = Set(chats.map(\.id))
        return rules.config.mutedChatIDs.filter { !known.contains($0) }.sorted()
    }

    private func muteBinding(_ chatID: String) -> Binding<Bool> {
        Binding(
            get: { rules.isMuted(chatID: chatID) },
            set: { rules.setMuted(chatID: chatID, muted: $0) })
    }

    private func muteHelp(chatID: String) -> String {
        rules.isMuted(chatID: chatID)
            ? "Muted: no banners, no unread. Flip off to unmute."
            : "Flip on to mute: no banners, no unread."
    }

    private var account: AccountInfo {
        if let fixedAccount { return fixedAccount }
        return AccountInfo.from(authState: auth.state, status: auth.status)
    }

    /// Read-only system grant state (requested once at live launch).
    private var permissionText: String {
        switch notifs.authorized {
        case .some(true): "Allowed"
        case .some(false): "Denied"
        case .none: "Unknown"
        }
    }
}
