// PinnedChats.swift — om-pin-top: Mentions + Notifications synthetic rows.
//
// Two synthetic rows sit above every real chat, always in this order:
// Mentions, Notifications, then recency. This enum owns the ChatList sort
// comparator: rank-only ordering over a stable partition, so ingest
// bubbling, filter-clear, and restart-restore can never move a real chat
// above them.
//
// The rows are plain ChatItems with stable synthetic ids (the `om-`
// prefix never collides with Teams conversation ids). The view model keeps
// real chats in `chats` and exposes the pinned projection as
// `displayChats`; the sidebar filters the projection. Unread counts live in
// UnreadStore keyed by chat id, so pinning never touches them (no reset,
// no accrual here).
import Foundation
import OstMacCore

/// Synthetic pinned rows + the ChatList sort comparator. Pure; every
/// branch covered by tests.
public enum PinnedChats {
    /// Stable id of the Mentions row (rank 0).
    public static let mentionsID = "om-synthetic-mentions"
    /// Stable id of the Notifications row (rank 1).
    public static let notificationsID = "om-synthetic-notifications"

    /// Factory Mentions row. Group-marked so no presence dot renders.
    public static let mentionsRow = ChatItem(
        chatId: mentionsID, name: "Mentions", is_group: true)
    /// Factory Notifications row. Group-marked so no presence dot renders.
    public static let notificationsRow = ChatItem(
        chatId: notificationsID, name: "Notifications", is_group: true)

    /// True for the two synthetic ids, false for every real chat id.
    public static func isSynthetic(_ id: String) -> Bool {
        id == mentionsID || id == notificationsID
    }

    /// Pin rank: Mentions 0, Notifications 1, every real chat 2.
    public static func rank(of id: String) -> Int {
        switch id {
        case mentionsID: return 0
        case notificationsID: return 1
        default: return 2
        }
    }

    /// The ChatList sort comparator: rank-only. Real chats compare equal
    /// (never reorder each other here — recency order comes from the
    /// stable partition in ``sorted(_:)``).
    public static func orderedBefore(_ a: ChatItem, _ b: ChatItem) -> Bool {
        rank(of: a.id) < rank(of: b.id)
    }

    /// Factory row for a synthetic id, nil for real/unknown ids.
    public static func row(for id: String) -> ChatItem? {
        switch id {
        case mentionsID: return mentionsRow
        case notificationsID: return notificationsRow
        default: return nil
        }
    }

    /// Pin the synthetic rows above recency: Mentions, Notifications,
    /// then the input's real chats in their original order (stable —
    /// ingest bubbling and core recency pass through untouched).
    /// Missing synthetic rows are inserted from the factory; incoming
    /// synthetic rows keep their own preview/sender/time; duplicate ids
    /// collapse to their first occurrence. Idempotent.
    public static func sorted(_ chats: [ChatItem]) -> [ChatItem] {
        var seen = Set<String>()
        var mentions: ChatItem?
        var notifications: ChatItem?
        var rest: [ChatItem] = []
        rest.reserveCapacity(chats.count + 2)
        for chat in chats {
            guard seen.insert(chat.id).inserted else { continue }
            switch chat.id {
            case mentionsID:
                mentions = chat
            case notificationsID:
                notifications = chat
            default:
                rest.append(chat)
            }
        }
        return [mentions ?? mentionsRow, notifications ?? notificationsRow] + rest
    }
}
