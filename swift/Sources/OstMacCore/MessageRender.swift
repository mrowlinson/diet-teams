// MessageRender.swift — om-convrich lane: rich bubble text + day sections.
//
// Rendering model: core ships stripped `content` (ost strip_html) plus the
// unstripped `raw` HTML. We render from `content` and mine `raw` for span
// positions (mentions, code blocks) — never render raw HTML directly, so
// bubble colors stay in control (no black-on-blue from HTML defaults).
import Foundation
import SwiftUI

/// Pure rendering helpers. No view code except the AttributedString builder.
public enum MessageRender {
    // MARK: - Entity decoding (mirrors ost strip_html's entity list)

    private static let entities: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
    ]

    public static func decodeEntities(_ s: String) -> String {
        var out = s
        for (e, c) in entities { out = out.replacingOccurrences(of: e, with: c) }
        return out
    }

    // MARK: - Raw-HTML mining

    /// Names inside `<at …>Name</at>` mention tags, entity-decoded.
    public static func mentions(fromRaw raw: String?) -> [String] {
        guard let raw else { return [] }
        return innerTexts(of: "at", in: raw).map(decodeEntities).filter { !$0.isEmpty }
    }

    /// Inner text of `<pre>…</pre>` code blocks, tags stripped, decoded.
    public static func codeBlocks(fromRaw raw: String?) -> [String] {
        guard let raw else { return [] }
        return innerTexts(of: "pre", in: raw)
            .map { decodeEntities(stripTags($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Text between `<tag …>` and `</tag>` (case-insensitive tag name).
    static func innerTexts(of tag: String, in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        let open = "<" + tag, close = "</" + tag + ">"
        while let s = rest.range(of: open, options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">"),
              let e = rest[gt...].range(of: close, options: .caseInsensitive)
        {
            out.append(String(rest[rest.index(after: gt) ..< e.lowerBound]))
            rest = rest[e.upperBound...]
        }
        return out
    }

    /// Tag stripper mirroring ost strip_html (no entity decoding).
    public static func stripTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            switch ch {
            case "<": inTag = true
            case ">": inTag = false
            default: if !inTag { out.append(ch) }
            }
        }
        return out
    }

    // MARK: - Day sections

    /// "2026-09-22T12:53:06…" -> "2026-09-22". Garbage -> "" (own section).
    public static func dayKey(_ iso: String) -> String {
        let t = iso.trimmingCharacters(in: .whitespaces)
        guard t.count >= 10 else { return t }
        let k = String(t.prefix(10))
        return k.count == 10 && k[k.index(k.startIndex, offsetBy: 4)] == "-"
            ? k : t
    }

    /// "2026-09-22" -> "Today" / "Yesterday" / "22 Sep 2026".
    public static func dayLabel(_ key: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        let cal = Calendar.current
        guard let d = f.date(from: key) else { return key.isEmpty ? "Unknown date" : key }
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }

    public struct DaySection: Sendable {
        public let key: String
        public let label: String
        public let messages: [ChatMessage]
    }

    /// Chronological messages -> day groups, order preserved.
    public static func daySections(_ messages: [ChatMessage]) -> [DaySection] {
        var out: [DaySection] = []
        for m in messages {
            let k = dayKey(m.timestamp)
            if out.last?.key == k {
                let last = out.removeLast()
                out.append(DaySection(key: k, label: last.label, messages: last.messages + [m]))
            } else {
                out.append(DaySection(key: k, label: dayLabel(k), messages: [m]))
            }
        }
        return out
    }

    // MARK: - Span ranges over plain content

    /// Ranges of `needle` occurrences (literal, case-sensitive).
    static func ranges(of needle: String, in hay: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var rest = hay.startIndex ..< hay.endIndex
        while let r = hay.range(of: needle, range: rest) {
            out.append(r)
            rest = r.upperBound ..< hay.endIndex
        }
        return out
    }

    /// `code` spans: single-backtick pairs, no newlines inside.
    public static func backtickSpans(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var rest = text.startIndex ..< text.endIndex
        while let open = text.range(of: "`", range: rest) {
            let after = open.upperBound ..< text.endIndex
            guard let shut = text.range(of: "`", range: after) else { break }
            let inner = open.upperBound ..< shut.lowerBound
            if !text[inner].isEmpty, !text[inner].contains("\n") { out.append(inner) }
            rest = shut.upperBound ..< text.endIndex
        }
        return out
    }

    // MARK: - AttributedString builder

    /// Styled body: mention names bold, code blocks + `spans` monospaced,
    /// URLs linked. Base font/color come from the caller's Text environment.
    public static func attributedBody(for message: ChatMessage) -> AttributedString {
        var a = AttributedString(message.content)
        let text = message.content
        func convert(_ r: Range<String.Index>) -> Range<AttributedString.Index>? {
            Range(r, in: a)
        }
        // Mentions (names mined from <at> tags; fall back to @token scan).
        var names = mentions(fromRaw: message.raw)
        if names.isEmpty {
            names = mentionTokens(in: text)
        }
        for n in names {
            for r in ranges(of: n, in: text) {
                guard let ar = convert(r) else { continue }
                a[ar].font = .body.bold()
            }
        }
        // Code blocks from <pre> + backtick spans.
        for b in codeBlocks(fromRaw: message.raw) {
            for r in ranges(of: b, in: text) {
                guard let ar = convert(r) else { continue }
                a[ar].font = .body.monospaced()
            }
        }
        for r in backtickSpans(in: text) {
            guard let ar = convert(r) else { continue }
            a[ar].font = .body.monospaced()
        }
        // URLs.
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = text as NSString
            for m in det.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url,
                      let r = Range(m.range, in: text),
                      let ar = convert(r)
                else { continue }
                a[ar].link = url
                a[ar].underlineStyle = .single
            }
        }
        return a
    }

    /// `@Name` tokens when no `<at>` tags exist (plain-text path).
    /// Matches @ + letters/spaces/commas/dots/apostrophes, up to 40 chars.
    static func mentionTokens(in text: String) -> [String] {
        var out: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "@" else { i = text.index(after: i); continue }
            var j = text.index(after: i)
            var count = 0
            while j < text.endIndex, count < 40 {
                let c = text[j]
                if c.isLetter || c == " " || c == "," || c == "." || c == "'" || c == "-" {
                    j = text.index(after: j); count += 1
                } else { break }
            }
            let name = String(text[text.index(after: i) ..< j])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.append(name) }
            i = j
        }
        return out
    }
}
