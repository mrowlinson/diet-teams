// ChatListFormat.swift — row text formatting (pure, deterministic, tested).
import Foundation
import OstMacCore

/// Formats core `last_message_*` strings for sidebar rows.
public enum ChatListFormat {
    /// Short timestamp: `HH:mm` today, weekday (`Mon`) within 7 days,
    /// `M/d` older. `nil`/blank → `""`. Unparseable → trimmed passthrough.
    public static func previewTime(
        _ raw: String?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return "" }
        guard let date = parse(trimmed) else { return trimmed }
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        if startDate == startNow {
            return styled(date, "HH:mm", calendar)
        }
        if let days = calendar.dateComponents([.day], from: startDate, to: startNow).day,
           days >= 0, days < 7
        {
            return styled(date, "EEE", calendar)
        }
        return styled(date, "M/d", calendar)
    }

    /// Case-insensitive substring filter over name/sender/preview.
    /// Blank query → all chats, in order.
    public static func filter(_ chats: [ChatItem], query: String) -> [ChatItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chats }
        return chats.filter { chat in
            chat.name.lowercased().contains(q)
                || (chat.last_message_sender?.lowercased().contains(q) ?? false)
                || (chat.last_message_preview?.lowercased().contains(q) ?? false)
        }
    }

    /// Mentions-only filter (om-mentions): keep chats whose id is in
    /// `mentionedIDs` (the MentionStore flag set). Order is preserved
    /// exactly — filtering never re-sorts (pin-top owns the comparator).
    /// Empty set → no chats (the row shows its "no mentions" state).
    /// Unknown ids are ignored.
    public static func filterMentions(_ chats: [ChatItem], mentionedIDs: Set<String>) -> [ChatItem] {
        guard !mentionedIDs.isEmpty else { return [] }
        return chats.filter { mentionedIDs.contains($0.id) }
    }

    /// Hidden filter (om-mute-hide): drop chats whose id is in
    /// `hiddenIDs` (the RulesStore hidden set). Order is preserved
    /// exactly. `showHidden` bypasses (restore pass: every chat shows).
    /// Empty set → all chats. Unknown ids are ignored.
    public static func filterHidden(_ chats: [ChatItem], hiddenIDs: Set<String>, showHidden: Bool = false) -> [ChatItem] {
        guard !showHidden, !hiddenIDs.isEmpty else { return chats }
        return chats.filter { !hiddenIDs.contains($0.id) }
    }

    /// One-line `sender: preview` summary. Missing parts are dropped;
    /// both missing → `""` (view shows a placeholder).
    public static func previewLine(sender: String?, preview: String?) -> String {
        let s = sender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let p = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (s.isEmpty, p.isEmpty) {
        case (false, false): return "\(s): \(p)"
        case (false, true): return s
        case (true, false): return p
        case (true, true): return ""
        }
    }

    // Core emits Teams ISO-8601 (`original_arrival_time`/`compose_time`),
    // with or without fractional seconds.
    static func parse(_ s: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func styled(_ date: Date, _ format: String, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }
}
