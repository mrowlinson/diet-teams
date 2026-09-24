// MentionAlerts.swift — om-mention-alerts lane: elevated mention alerts.
//
// @me/@team mentions break through mute (global + Teams per-chat) with a
// distinct banner (OM_MENTION category, "Mentioned you"/"Channel mention"
// subtitle) and a distinct sound (critical vs default). They do NOT break
// through Do-Not-Disturb (own Teams presence = DoNotDisturb) or quiet
// hours (local schedule): those suppress everything, mentions included.
//
// Suppression order (ChatFilter): DND > quiet hours > mute-with-breakthrough
// > keyword-block > structural/meeting > keyword-allow > own/type/edit/noisy.
// The Mentions row flag set is the review queue (mute/DND/quiet never stop
// flagging — opening the chat clears it); its count drives the Dock tile,
// so the badge survives banner suppression. Alert counters live in
// Diagnostics only (never the sidebar, never the banner).
import Foundation
import UserNotifications

/// Elevated-mention alert surface: reasons, categories, sound + subtitle.
/// Pure (tested); the UN posting lives in the notifiers.
public enum MentionAlert {
    /// Notify reason when a mention breaks through mute.
    public static let breakthroughReason = "mention-breakthrough"
    /// Skip reason under Do-Not-Disturb (beats mute + breakthrough).
    public static let dndReason = "dnd"
    /// Skip reason inside quiet hours (beats mute + breakthrough).
    public static let quietReason = "quiet-hours"

    /// Banner category for elevated mentions (Reply + Open chat).
    public static let categoryID = "OM_MENTION"
    /// Mention category when Reply is unwired (Open chat only).
    public static let categoryNoReplyID = "OM_MENTION_NOREPLY"

    /// Elevated mention? Owner (@me) or channel/team/everyone (@team).
    /// Same gates as the noisy-chat rules: MRI preferred, display-name
    /// backup unless matchByName is false. Blank owners never match.
    public static func isElevated(
        mentions: [Mention], ownerMRI: String?,
        ownerDisplayName: String, matchByName: Bool = true
    ) -> Bool {
        Mentions.mentionsOwner(
            mentions, ownerMRI: ownerMRI,
            ownerDisplayName: ownerDisplayName, matchByName: matchByName)
            || Mentions.mentionsChannelOrEveryone(mentions)
    }

    /// Convenience over a live event's mined mentions.
    public static func isElevated(
        message: RealtimeMessage, ownerMRI: String?,
        ownerDisplayName: String, matchByName: Bool = true
    ) -> Bool {
        isElevated(
            mentions: message.mentions, ownerMRI: ownerMRI,
            ownerDisplayName: ownerDisplayName, matchByName: matchByName)
    }

    /// Banner subtitle for an elevated mention: owner mentions name you,
    /// channel-only mentions name the blast. Nil when neither (plain).
    public static func subtitle(ownerMention: Bool, channelMention: Bool) -> String? {
        if ownerMention { return "Mentioned you" }
        if channelMention { return "Channel mention" }
        return nil
    }

    /// Banner sound: mentions play the critical tone, plain the default.
    /// The interruption level stays default (never time-sensitive): app
    /// DND/quiet suppress posting entirely, and system Focus keeps the
    /// user's own settings.
    public enum Sound: String, Sendable, Equatable {
        case `default`
        case critical
    }

    public static func sound(isMention: Bool) -> Sound {
        isMention ? .critical : .default
    }

    /// Do-Not-Disturb from the own Teams availability (PresenceStore.own).
    /// Only DoNotDisturb suppresses; every other value (and unknown/nil)
    /// alerts normally.
    public static func isDND(ownAvailability: String?) -> Bool {
        ownAvailability == "DoNotDisturb"
    }
}

extension MentionAlert.Sound {
    /// UN sound for the alert level.
    public var unSound: UNNotificationSound {
        switch self {
        case .default: .default
        case .critical: .defaultCritical
        }
    }
}

/// Local quiet-hours schedule: inside the window no banner or sound posts
/// (mentions included). Overnight windows (start > end) wrap midnight.
/// Disabled — or equal bounds (a degenerate empty window) — never fires.
public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Minutes after midnight, clamped to 0..<1440.
    public var startMinutes: Int
    public var endMinutes: Int

    public init(enabled: Bool = false, startMinutes: Int = 22 * 60, endMinutes: Int = 7 * 60) {
        self.enabled = enabled
        self.startMinutes = Self.clamp(startMinutes)
        self.endMinutes = Self.clamp(endMinutes)
    }

    static func clamp(_ m: Int) -> Int {
        min(1439, max(0, m))
    }

    /// True when date falls inside the window (and enabled). Start is
    /// inclusive, end exclusive.
    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        guard startMinutes != endMinutes else { return false }
        let mins = Self.minutesOfDay(date, calendar: calendar)
        if startMinutes < endMinutes {
            return mins >= startMinutes && mins < endMinutes
        }
        return mins >= startMinutes || mins < endMinutes
    }

    /// Minutes after midnight for a wall-clock time.
    public static func minutesOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Today at the given minutes after midnight (Settings pickers).
    public static func date(forMinutes mins: Int, calendar: Calendar = .current) -> Date {
        let now = Date()
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day,
            hour: clamp(mins) / 60, minute: clamp(mins) % 60)) ?? now
    }

    /// "off" when disabled, else "22:00–07:00" (24h, locale-independent).
    public var summary: String {
        guard enabled else { return "off" }
        return "\(Self.clock(startMinutes))–\(Self.clock(endMinutes))"
    }

    static func clock(_ mins: Int) -> String {
        String(format: "%02d:%02d", clamp(mins) / 60, clamp(mins) % 60)
    }
}

/// Quiet-hours schedule store (Settings binds here; persisted). The rules
/// decision reads `isActiveNow()` per event — no chat-list refresh.
@MainActor
public final class QuietHoursStore: ObservableObject {
    public static let enabledKey = "quiet.enabled"
    public static let startKey = "quiet.startMinutes"
    public static let endKey = "quiet.endMinutes"

    @Published public var hours: QuietHours {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    /// Nonisolated so views can take a default `QuietHoursStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var hours = QuietHours()
        if defaults.object(forKey: Self.enabledKey) != nil {
            hours.enabled = defaults.bool(forKey: Self.enabledKey)
        }
        if defaults.object(forKey: Self.startKey) != nil {
            hours.startMinutes = QuietHours.clamp(defaults.integer(forKey: Self.startKey))
        }
        if defaults.object(forKey: Self.endKey) != nil {
            hours.endMinutes = QuietHours.clamp(defaults.integer(forKey: Self.endKey))
        }
        _hours = Published(initialValue: hours)
    }

    /// Live suppression state for the rules decision.
    public func isActiveNow(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        hours.isActive(at: date, calendar: calendar)
    }

    private func persist() {
        defaults.set(hours.enabled, forKey: Self.enabledKey)
        defaults.set(hours.startMinutes, forKey: Self.startKey)
        defaults.set(hours.endMinutes, forKey: Self.endKey)
    }
}

/// No-op dock sink: the app wires UnreadStore to this so the Mentions row
/// count owns the tile alone (unread counts stay sidebar + Diagnostics).
public final class NullDockBadge: DockBadging, @unchecked Sendable {
    public init() {}

    public func setBadge(_ label: String?) {}
}
