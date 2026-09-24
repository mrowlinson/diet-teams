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
//
// om-pindedupe: a real thread whose name matches a pinned row
// ("Notifications", "Mentions") shares that row's stable identity —
// without dedupe the sidebar shows two same-named rows. `sorted(_:)`
// collapses each pinned slot to exactly one row: the real thread wins
// over any synthetic row (a real conversation is never hidden), keeps
// the pinned position, and keeps its own id so its unread/counts
// entries still apply. Real threads never dedupe against each other:
// same-named extras stay in recency.
//
// om-userpins: user-pinned chats form a third section between the two
// synthetic rows and recency, in pin-time order (oldest pin first).
// `sorted(_:pins:)` extends the pindedupe partition — the synthetic
// occupant logic is unchanged, and a pinned chat that already
// occupies a synthetic slot stays there (never duplicated below).
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

    /// True when a chat id can be user-pinned: a non-blank real id.
    /// Synthetic rows are already pinned by construction (pinning
    /// them would duplicate the top-two slots), so they refuse.
    public static func isPinnable(_ id: String) -> Bool {
        !isSynthetic(id)
            && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stable identity shared by a synthetic row and any real thread
    /// that would render as the same entry: the synthetic id itself
    /// for synthetic rows; for real threads, the pinned slot id whose
    /// factory name the thread's name matches (trimmed,
    /// case-insensitive); otherwise the thread's own id. Pure.
    public static func stableID(for chat: ChatItem) -> String {
        if isSynthetic(chat.id) { return chat.id }
        let name = chat.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == mentionsRow.name.lowercased() { return mentionsID }
        if name == notificationsRow.name.lowercased() { return notificationsID }
        return chat.id
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
    /// Missing slots backfill from the factory; incoming synthetic
    /// rows keep their own preview/sender/time; duplicate ids collapse
    /// to their first occurrence. Idempotent.
    ///
    /// om-pindedupe: each pinned slot holds exactly one row. A real
    /// thread sharing the slot's stable identity (see `stableID(for:)`)
    /// is promoted into the pinned position and the synthetic row is
    /// dropped — the survivor keeps its own id, so unread/counts keyed
    /// by that id still apply. Real threads never collapse into each
    /// other: same-named extras stay in recency order.
    ///
    /// Shorthand for `sorted(_:pins:)` with no user pins.
    public static func sorted(_ chats: [ChatItem]) -> [ChatItem] {
        sorted(chats, pins: [])
    }

    /// Full sidebar order: the two synthetic occupants (pindedupe
    /// partition, unchanged), then user-pinned chats in pin-time
    /// order (oldest pin first — `pins` array order), then the
    /// remaining real chats in their original order. Unknown pin
    /// ids (chat gone or beyond the fetch window) don't render
    /// but stay in `pins` (the store never prunes — a later fetch
    /// restores the row); synthetic pin ids and duplicate pins
    /// are skipped; a pinned chat that already occupies a
    /// synthetic slot stays there (never duplicated below).
    /// Idempotent for a fixed pin list.
    public static func sorted(_ chats: [ChatItem], pins: [String]) -> [ChatItem] {
        var seen = Set<String>()
        var unique: [ChatItem] = []
        unique.reserveCapacity(chats.count)
        for chat in chats {
            guard seen.insert(chat.id).inserted else { continue }
            unique.append(chat)
        }
        let mentions = occupant(slotID: mentionsID, factory: mentionsRow, in: unique)
        let notifications = occupant(slotID: notificationsID, factory: notificationsRow, in: unique)
        let occupantIDs: Set<String> = [mentions.id, notifications.id]
        var byID: [String: ChatItem] = [:]
        byID.reserveCapacity(unique.count)
        for chat in unique where byID[chat.id] == nil {
            byID[chat.id] = chat
        }
        var pinned: [ChatItem] = []
        pinned.reserveCapacity(pins.count)
        var pinnedIDs = Set<String>()
        for id in pins {
            guard isPinnable(id) else { continue }
            guard !occupantIDs.contains(id) else { continue }
            guard pinnedIDs.insert(id).inserted else { continue }
            guard let chat = byID[id] else { continue }
            pinned.append(chat)
        }
        var rest: [ChatItem] = []
        rest.reserveCapacity(unique.count)
        for chat in unique {
            if occupantIDs.contains(chat.id) { continue }
            if pinnedIDs.contains(chat.id) { continue }
            if isSynthetic(chat.id) { continue }
            rest.append(chat)
        }
        return [mentions, notifications] + pinned + rest
    }

    /// One slot's occupant: the first real thread sharing the slot's
    /// stable identity wins over any synthetic row (never hide a real
    /// conversation); otherwise the first claimant; otherwise factory.
    private static func occupant(slotID: String, factory: ChatItem, in chats: [ChatItem]) -> ChatItem {
        var first: ChatItem?
        for chat in chats where stableID(for: chat) == slotID {
            if first == nil { first = chat }
            if !isSynthetic(chat.id) { return chat }
        }
        return first ?? factory
    }
}
