// JumpPalette.swift — om-cmdk lane: fuzzy jump-to targets + matcher.
// Pure model (no SwiftUI): JumpTarget rows built from chats + teams,
// FuzzyMatch subsequence scoring + ranked filter. The view lives in
// JumpPaletteView.swift; App.swift sheets it on Cmd+K.
import Foundation
import OstMacCore

/// One jump destination: a chat, a channel, or a team.
public struct JumpTarget: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case chat
        case channel
        case team
    }

    /// Stable row id (chat id, channel id, or team id).
    public let id: String
    /// Conversation id to open, nil when not openable (channel-less team).
    public let openID: String?
    /// Display name passed to open().
    public let openName: String
    public let title: String
    public let subtitle: String
    public let kind: Kind

    public init(
        id: String, openID: String?, openName: String,
        title: String, subtitle: String, kind: Kind
    ) {
        self.id = id
        self.openID = openID
        self.openName = openName
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}

/// Builds palette rows: chats, then channels (team-qualified), then teams
/// (open their first channel; nil when the team has no channels).
public enum JumpTargets {
    public static func build(chats: [ChatItem], teams: [TeamItem]) -> [JumpTarget] {
        var out: [JumpTarget] = []
        for c in chats {
            out.append(JumpTarget(
                id: c.id, openID: c.id, openName: c.name,
                title: c.name, subtitle: c.is_group ? "Group chat" : "Chat",
                kind: .chat))
        }
        for t in teams {
            for ch in t.channels {
                out.append(JumpTarget(
                    id: ch.id, openID: ch.id,
                    openName: "\(t.name) > #\(ch.name)",
                    title: "#\(ch.name)", subtitle: t.name,
                    kind: .channel))
            }
        }
        for t in teams {
            let first = t.channels.first
            out.append(JumpTarget(
                id: t.id, openID: first?.id,
                openName: first.map { "\(t.name) > #\($0.name)" } ?? t.name,
                title: t.name,
                subtitle: t.channels.isEmpty ? "Team · no channels"
                    : "Team · \(t.channels.count) channel\(t.channels.count == 1 ? "" : "s")",
                kind: .team))
        }
        return out
    }
}

/// Subsequence fuzzy match. Score is higher for better matches; nil when
/// the query is not a subsequence of the target (no match).
///
/// +10 per matched char, +8 when the match starts a word, +4 for an
/// exact-case match, +2 per adjacency with the previous match, −1 per
/// skipped char. Case-insensitive.
public enum FuzzyMatch {
    public static func score(query: String, target: String) -> Int? {
        let q = Array(query)
        guard !q.isEmpty else { return 0 }
        let t = Array(target)
        var qi = 0
        var total = 0
        var prevMatch = -2
        var ti = 0
        while ti < t.count, qi < q.count {
            let qc = q[qi]
            // Scan forward for the next query char (case-insensitive).
            var found: Int?
            var j = ti
            while j < t.count {
                if t[j].lowercased() == qc.lowercased() { found = j; break }
                j += 1
            }
            guard let m = found else { return nil }
            total -= (m - ti) // skipped chars
            total += 10
            if m == 0 || t[m - 1] == " " || t[m - 1] == "-" || t[m - 1] == "_" || t[m - 1] == ">" || t[m - 1] == "#" {
                total += 8 // word-boundary start
            }
            if String(t[m]) == String(qc) { total += 4 } // exact case
            if m == prevMatch + 1 { total += 2 } // adjacency
            prevMatch = m
            ti = m + 1
            qi += 1
        }
        return qi == q.count ? total : nil
    }

    /// Targets matching `query`, best first (ties keep input order).
    /// Empty query returns all targets in order. Matches against the
    /// title, then both team-qualified orders, so "eng ship" finds
    /// Engineering > #Shipping either way round. Qualified hits rank
    /// below direct title hits.
    public static func ranked(_ targets: [JumpTarget], query: String) -> [JumpTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return targets }
        var scored: [(Int, Int, JumpTarget)] = []
        for (i, t) in targets.enumerated() {
            let candidates = [
                (t.title, 0),
                ("\(t.subtitle) \(t.title)", -5),
                ("\(t.title) \(t.subtitle)", -5),
            ]
            for (cand, penalty) in candidates {
                if let s = score(query: q, target: cand) {
                    scored.append((s + penalty, i, t))
                    break
                }
            }
        }
        return scored.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.2)
    }
}

public extension Notification.Name {
    /// Posted by the Go-menu Cmd+K command; RootView sheets the palette.
    static let showJumpPalette = Notification.Name("om-cmdk.showJumpPalette")
}
