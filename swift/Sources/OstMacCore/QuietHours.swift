// QuietHours.swift — om-quiet-hours lane: scheduled quiet hours + manual DND.
//
// Banners and sounds pause while quiet is active; mention flags and
// Diagnostics counters keep accruing, but unread pauses too —
// quiet-hours skips never accrue (the Mentions row stays the review
// queue). The live quiet state feeds the rules engine (ChatFilter)
// as its second gate (presence-DND first, then quiet, then
// mute-with-mention-breakthrough); the banner path ALSO obeys the
// snapshot (defense in depth + suppressed counting).
//
// Two independent sources (either one quiets the app):
// - Schedule: a daily QuietHoursWindow (start/end minutes + weekday set).
//   Overnight windows (start > end, e.g. 22:00–07:00) span midnight: the
//   evening arm belongs to each selected day, the morning arm to the day
//   after. start == end means the window never fires (not all-day).
// - Manual DND: an on/off toggle with auto-expiry (30 min, 1/4 hours,
//   until 8 AM local, or until turned off). Expiry sweeps lazily on
//   every quiet check plus the app's 2s status tick.
//
// Persistence: UserDefaults (suite-injectable for tests), one key per
// field — MessageNotifications precedent. The suppressed-banner count
// is session-only and surfaces in Diagnostics ONLY (never the sidebar,
// never Settings, no list refresh anywhere on this path).
import Foundation

/// Daily schedule window: notify-silence between start and end on the
/// selected weekdays. Minutes are local minutes-since-midnight
/// (0..<1440, clamped); weekdays are Calendar numbers (1 = Sunday).
public struct QuietHoursWindow: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var startMinutes: Int
    public var endMinutes: Int
    /// Selected weekdays, 1...7 (1 = Sunday). Unsorted/dupes tolerated.
    public var days: [Int]

    public init(
        enabled: Bool = false,
        startMinutes: Int = 22 * 60,
        endMinutes: Int = 7 * 60,
        days: [Int] = [1, 2, 3, 4, 5, 6, 7]
    ) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.days = days
    }

    /// Minutes in a day (exclusive upper bound after clamping).
    public static let dayMinutes = 24 * 60

    /// Clamp to a valid minute-of-day.
    public static func norm(_ minutes: Int) -> Int {
        min(max(minutes, 0), dayMinutes - 1)
    }

    /// Local minutes-since-midnight of a date.
    public static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
    }

    /// True when the window spans midnight (evening arm + morning arm).
    public var isOvernight: Bool {
        let s = Self.norm(startMinutes), e = Self.norm(endMinutes)
        return s != e && s > e
    }

    /// True when start == end: the window never fires (explicitly NOT
    /// all-day — an all-day silence is the DND toggle's job).
    public var isEmpty: Bool {
        Self.norm(startMinutes) == Self.norm(endMinutes)
    }

    /// True when `date` falls inside the window. Disabled or empty
    /// windows never match. Same-day windows match [start, end) on a
    /// selected weekday; overnight windows match [start, 24h) on a
    /// selected day plus [0, end) the morning after (so a Friday-only
    /// 22:00–07:00 window covers Fri 22:00+ AND Sat 00:00–07:00, but
    /// neither Fri 06:00 nor Sat 23:00).
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, !isEmpty else { return false }
        let start = Self.norm(startMinutes), end = Self.norm(endMinutes)
        let mins = Self.minutes(of: date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: date)
        let selected = Set(days)
        if start < end {
            return selected.contains(weekday) && mins >= start && mins < end
        }
        // Overnight: evening arm on the day itself, morning arm the day after.
        if mins >= start { return selected.contains(weekday) }
        if mins < end {
            let yesterday = ((weekday + 5) % 7) + 1 // weekday - 1, wrapped 1...7
            return selected.contains(yesterday)
        }
        return false
    }

    /// "22:00" style label (24h, deterministic across locales).
    public static func label(minutes: Int) -> String {
        let m = norm(minutes)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// "22:00–07:00" style range label.
    public var rangeLabel: String {
        "\(Self.label(minutes: startMinutes))–\(Self.label(minutes: endMinutes))"
    }

    /// "every day" / "weekdays" / "weekends" / "Sun, Tue" style day summary.
    public func daysSummary(calendar: Calendar = .current) -> String {
        let set = Set(days)
        if set.count >= 7 { return "every day" }
        if set == Set([2, 3, 4, 5, 6]) { return "weekdays" }
        if set == Set([1, 7]) { return "weekends" }
        if set.isEmpty { return "no days" }
        let symbols = calendar.shortWeekdaySymbols
        return set.sorted().map { symbols[($0 - 1 + symbols.count) % symbols.count] }
            .joined(separator: ", ")
    }

    /// "22:00–07:00 · every day" (Diagnostics schedule row).
    public func summary(calendar: Calendar = .current) -> String {
        "\(rangeLabel) · \(daysSummary(calendar: calendar))"
    }
}

/// Manual DND auto-expiry options (Settings picker + store).
public enum DNDDuration: String, CaseIterable, Sendable {
    case thirtyMinutes
    case oneHour
    case fourHours
    case untilMorning
    case untilTurnedOff

    /// Picker label.
    public var label: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .untilMorning: "Until 8 AM"
        case .untilTurnedOff: "Until turned off"
        }
    }

    /// Expiry instant for `now` (nil = indefinite). Until-morning is the
    /// next local 08:00 (today's when still ahead, else tomorrow's).
    public func expiryDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .thirtyMinutes: return calendar.date(byAdding: .minute, value: 30, to: now)
        case .oneHour: return calendar.date(byAdding: .hour, value: 1, to: now)
        case .fourHours: return calendar.date(byAdding: .hour, value: 4, to: now)
        case .untilTurnedOff: return nil
        case .untilMorning:
            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            comps.hour = 8
            comps.minute = 0
            comps.second = 0
            guard let today8 = calendar.date(from: comps) else { return nil }
            if now < today8 { return today8 }
            return calendar.date(byAdding: .day, value: 1, to: today8)
        }
    }
}

/// Pure suppression-count gate (AppState calls this; tests assert it
/// directly — the app target itself has no test bundle).
public enum QuietHoursGate {
    /// True when this event's banner was suppressed AND worth counting:
    /// quiet is on, banners are enabled at all, and at least one banner
    /// path (rules-driven or legacy non-open-chat) would have posted.
    /// Counted at most once per event (both paths firing still counts 1).
    public static func countsSuppression(
        quiet: Bool, bannersEnabled: Bool,
        rulesNotified: Bool, legacyWouldPost: Bool
    ) -> Bool {
        quiet && bannersEnabled && (rulesNotified || legacyWouldPost)
    }
}

/// Quiet-hours + DND state. Owns the schedule, the manual toggle, and
/// the session suppressed-banner count (Diagnostics only).
@MainActor
public final class QuietHoursStore: ObservableObject {
    public static let enabledKey = "quietHours.enabled"
    public static let startKey = "quietHours.startMinutes"
    public static let endKey = "quietHours.endMinutes"
    public static let daysKey = "quietHours.days"
    public static let dndOnKey = "quietHours.dndOn"
    public static let dndUntilKey = "quietHours.dndUntil"
    public static let dndPendingKey = "quietHours.dndPending"

    private let defaults: UserDefaults

    @Published public var windowEnabled = false {
        didSet { defaults.set(windowEnabled, forKey: Self.enabledKey) }
    }
    @Published public var startMinutes = 22 * 60 {
        didSet { defaults.set(startMinutes, forKey: Self.startKey) }
    }
    @Published public var endMinutes = 7 * 60 {
        didSet { defaults.set(endMinutes, forKey: Self.endKey) }
    }
    @Published public var days = [1, 2, 3, 4, 5, 6, 7] {
        didSet { defaults.set(days, forKey: Self.daysKey) }
    }
    @Published public var dndOn = false {
        didSet { defaults.set(dndOn, forKey: Self.dndOnKey) }
    }
    @Published public var dndUntil: Date? {
        didSet {
            if let dndUntil {
                defaults.set(dndUntil.timeIntervalSince1970, forKey: Self.dndUntilKey)
            } else {
                defaults.removeObject(forKey: Self.dndUntilKey)
            }
        }
    }
    /// Pending auto-expiry choice (the Settings picker; applied on enable,
    /// re-applied when changed while on).
    @Published public var pendingDNDOption = DNDDuration.oneHour {
        didSet { defaults.set(pendingDNDOption.rawValue, forKey: Self.dndPendingKey) }
    }
    /// Session banners suppressed (never persisted; Diagnostics only).
    @Published public private(set) var suppressedCount = 0

    /// Nonisolated so views can take a default `QuietHoursStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var enabled = false
        var start = 22 * 60
        var end = 7 * 60
        var days = [1, 2, 3, 4, 5, 6, 7]
        var dndOn = false
        var dndUntil: Date?
        var pending = DNDDuration.oneHour
        if defaults.object(forKey: Self.enabledKey) != nil {
            enabled = defaults.bool(forKey: Self.enabledKey)
        }
        if defaults.object(forKey: Self.startKey) != nil {
            start = defaults.integer(forKey: Self.startKey)
        }
        if defaults.object(forKey: Self.endKey) != nil {
            end = defaults.integer(forKey: Self.endKey)
        }
        if let saved = defaults.array(forKey: Self.daysKey) as? [Int], !saved.isEmpty {
            days = saved
        }
        if defaults.object(forKey: Self.dndOnKey) != nil {
            dndOn = defaults.bool(forKey: Self.dndOnKey)
        }
        if defaults.object(forKey: Self.dndUntilKey) != nil {
            dndUntil = Date(timeIntervalSince1970: defaults.double(forKey: Self.dndUntilKey))
        }
        if let raw = defaults.string(forKey: Self.dndPendingKey),
           let opt = DNDDuration(rawValue: raw)
        {
            pending = opt
        }
        // Launch sweep: DND that expired while away starts off.
        if dndOn, let until = dndUntil, Date() >= until {
            dndOn = false
            dndUntil = nil
        }
        _windowEnabled = Published(initialValue: enabled)
        _startMinutes = Published(initialValue: start)
        _endMinutes = Published(initialValue: end)
        _days = Published(initialValue: days)
        _dndOn = Published(initialValue: dndOn)
        _dndUntil = Published(initialValue: dndUntil)
        _pendingDNDOption = Published(initialValue: pending)
        _suppressedCount = Published(initialValue: 0)
    }

    /// Current schedule window (derived from the published fields).
    public var window: QuietHoursWindow {
        QuietHoursWindow(
            enabled: windowEnabled, startMinutes: startMinutes,
            endMinutes: endMinutes, days: days)
    }

    /// True when the schedule alone quiets `date` (pure — no sweep).
    public func scheduleActive(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        window.contains(date, calendar: calendar)
    }

    /// True when manual DND alone quiets `date` (pure — no sweep).
    /// Indefinite DND (nil expiry) stays on until disabled.
    public func dndActive(at date: Date = Date()) -> Bool {
        guard dndOn else { return false }
        guard let until = dndUntil else { return true }
        return date < until
    }

    /// True when either source quiets `date`. Sweeps expired DND first,
    /// so a stale toggle never sticks on (plus the app tick refreshes).
    public func isQuiet(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        refresh(now: date)
        return dndActive(at: date) || scheduleActive(at: date, calendar: calendar)
    }

    /// `isQuiet()` at now (banner gate shorthand).
    public var isQuietNow: Bool {
        isQuiet()
    }

    /// Clear DND whose expiry passed (no-op otherwise). Called from
    /// `isQuiet` and the app's status tick (drives the toggle UI off).
    public func refresh(now: Date = Date()) {
        if dndOn, let until = dndUntil, now >= until {
            dndOn = false
            dndUntil = nil
        }
    }

    /// Turn DND on with an expiry option (nil expiry = indefinite).
    public func enableDND(
        _ option: DNDDuration, now: Date = Date(), calendar: Calendar = .current
    ) {
        pendingDNDOption = option
        dndOn = true
        dndUntil = option.expiryDate(now: now, calendar: calendar)
    }

    /// Turn DND off (clears any expiry).
    public func disableDND() {
        dndOn = false
        dndUntil = nil
    }

    /// Count one suppressed banner (quiet was on and a banner path
    /// would have posted — see QuietHoursGate).
    public func noteSuppressed() {
        suppressedCount += 1
    }

    /// "on until 14:30" / "on until turned off" / "off" (Diagnostics row).
    public func dndStatus(at date: Date = Date(), calendar: Calendar = .current) -> String {
        guard dndActive(at: date) else { return "off" }
        guard let until = dndUntil else { return "on until turned off" }
        return "on until \(QuietHoursWindow.label(minutes: QuietHoursWindow.minutes(of: until, calendar: calendar)))"
    }

    // MARK: Settings picker bridges

    /// Today at `minutes` (DatePicker selection value for a bound field).
    nonisolated public static func timeOfDay(
        minutes: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> Date {
        let m = QuietHoursWindow.norm(minutes)
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = m / 60
        comps.minute = m % 60
        comps.second = 0
        return calendar.date(from: comps) ?? now
    }

    /// Minutes-since-midnight of a picked time (DatePicker write-back).
    nonisolated public static func minutes(ofTime time: Date, calendar: Calendar = .current) -> Int {
        QuietHoursWindow.minutes(of: time, calendar: calendar)
    }
}
