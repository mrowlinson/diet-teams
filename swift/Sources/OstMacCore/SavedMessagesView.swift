// SavedMessagesView.swift — e2-saved lane: the saved collection view.
//
// ONE cross-chat list (newest-save-first) + a native search field + one
// row per save (chat/channel name, sender, snippet, time). Row tap jumps
// to the source bubble through the host's jump funnel; the ✕ unsaves.
// Empty collection renders a named empty view, never a blank pane.
//
// Native controls only (List / TextField / Button / Menu); diet tokens
// for type/color. Stable row identities (chat+message) — filtering and
// toggling never flash, skeleton, or reorder in place (zero-refresh).
import DietDesign
import SwiftUI

/// Saved collection sheet content (see SavedMessageStore).
public struct SavedMessagesView: View {
    @ObservedObject public var store: SavedMessageStore
    /// Loaded window for live-content resolve (usually the open chat's
    /// messages; other chats' rows render snapshots).
    public var live: [ChatMessage] = []
    /// Preview setting (Notifications.showPreview): OFF redacts snippets.
    public var showPreview: Bool = true
    /// Chat/channel display name for one id (host's chatNameOrNil).
    public var chatNameFor: (String) -> String? = { _ in nil }
    /// Row-tap jump (host's jumpToMessage funnel input).
    public var onJump: (SearchHit) -> Void = { _ in }

    public init(
        store: SavedMessageStore, live: [ChatMessage] = [],
        showPreview: Bool = true,
        chatNameFor: @escaping (String) -> String? = { _ in nil },
        onJump: @escaping (SearchHit) -> Void = { _ in }
    ) {
        self.store = store
        self.live = live
        self.showPreview = showPreview
        self.chatNameFor = chatNameFor
        self.onJump = onJump
    }

    /// Empty-state copy (single source).
    /// Pins-vs-saved distinction lives here: pins are the per-thread
    /// strip; saved is this cross-chat collection.
    public static let emptyImage = "bookmark"
    public static let emptyTitle = "No saved messages"
    public static let emptyMessage =
        "Save any message from its menu to keep it here across every chat and channel. " +
        "Pins stay on their own thread; saves collect here."
    public static let noMatchTitle = "No matching saves"
    public static let noMatchMessage =
        "No saved message matches this search. Clear the search to see everything."

    public var body: some View {
        VStack(spacing: 0) {
            TextField("Search saved messages", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, DietSpace.md)
                .padding(.vertical, DietSpace.sm)
                .accessibilityLabel("Search saved messages")
            DietSeamH()
            Group {
                if store.saves.isEmpty {
                    DietEmptyState(
                        systemImage: Self.emptyImage,
                        title: Self.emptyTitle,
                        message: Self.emptyMessage)
                        .accessibilityLabel(Self.emptyTitle)
                } else {
                    let rows = SavedMessages.rows(
                        saves: store.filtered(), live: live)
                    if rows.isEmpty {
                        DietEmptyState(
                            systemImage: "magnifyingglass",
                            title: Self.noMatchTitle,
                            message: Self.noMatchMessage)
                            .accessibilityLabel(Self.noMatchTitle)
                    } else {
                        List(rows) { row in
                            HStack(spacing: DietSpace.sm) {
                                Button {
                                    onJump(SavedMessages.hit(for: save(of: row)))
                                } label: {
                                    VStack(alignment: .leading, spacing: DietSpace.xxs) {
                                        Text(chatNameFor(row.chatID) ?? "Conversation")
                                            .font(DietType.caption1).bold()
                                            .foregroundStyle(DietColor.textPrimaryColor)
                                            .lineLimit(1)
                                        Text("\(row.sender) · \(ChatMessage.shortTime(row.timestamp))")
                                            .font(DietType.caption1)
                                            .foregroundStyle(DietColor.textSecondaryColor)
                                            .lineLimit(1)
                                        Text(SavedMessages.displayPreview(
                                            snippet: row.preview, showPreview: showPreview))
                                            .font(DietType.body)
                                            .foregroundStyle(DietColor.textSecondaryColor)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: DietSpace.sm)
                                }
                                .buttonStyle(.plain)
                                .help("Open the conversation at this message")
                                .accessibilityLabel(
                                    "Saved from \(row.sender): \(row.preview)")
                                Button {
                                    store.unsave(
                                        chatID: row.chatID, messageID: row.messageID)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: DietSize.iconMD))
                                        .foregroundStyle(DietColor.textTertiaryColor)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from saved")
                                .accessibilityLabel("Unsave message from \(row.sender)")
                            }
                            .padding(.vertical, DietSpace.xxs)
                        }
                        .listStyle(.inset)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .navigationTitle("Saved Messages")
    }

    /// Snapshot behind one row (the jump funnel's SearchHit input).
    private func save(of row: SavedMessages.SavedRow) -> SavedMessage {
        store.saves.first(where: {
            $0.chatID == row.chatID && $0.messageID == row.messageID
        }) ?? SavedMessage(
            chatID: row.chatID, teamID: row.teamID,
            channelID: row.channelID, messageID: row.messageID,
            sender: row.sender, preview: row.preview, content: row.preview,
            timestamp: row.timestamp, savedAt: row.savedAt)
    }
}
