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
    /// Runs over `renderText` (shortcodes expanded), so spans land on what
    /// the bubble shows.
    public static func attributedBody(for message: ChatMessage) -> AttributedString {
        let text = renderText(for: message)
        var a = AttributedString(text)
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

    // MARK: - Rich media (om-richmedia lane)

    /// One `<img>` mined from raw message HTML.
    public struct RichImage: Sendable, Equatable, Identifiable {
        public var id: String { url }
        public let url: String
        public let alt: String
        /// Emoticon art: explicit w/h ≤ 32, an emoticon marker attr, or a
        /// shortcode alt like `(smile)`. Renders small, not as a photo.
        public let isEmoticon: Bool

        public init(url: String, alt: String = "", isEmoticon: Bool = false) {
            self.url = url
            self.alt = alt
            self.isEmoticon = isEmoticon
        }
    }

    /// `<img …>` tags in raw HTML, in order. Tags without `src` are dropped.
    /// Tag/attr names are case-insensitive; values may be double-quoted,
    /// single-quoted, or bare. `alt` is entity-decoded.
    public static func images(fromRaw raw: String?) -> [RichImage] {
        guard let raw else { return [] }
        return imgTags(in: raw).compactMap { tag in
            let attrs = attributes(of: tag)
            guard let src = attrs["src"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !src.isEmpty
            else { return nil }
            return RichImage(
                url: decodeEntities(src),
                alt: decodeEntities(attrs["alt"] ?? ""),
                isEmoticon: isEmoticonTag(attrs))
        }
    }

    /// Raw `<img …>` tag spans (case-insensitive open, first `>` closes).
    static func imgTags(in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        while let s = rest.range(of: "<img", options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">")
        {
            out.append(String(rest[s.lowerBound ... gt]))
            rest = rest[rest.index(after: gt)...]
        }
        return out
    }

    /// Attr map of one tag (names lowercased). Tolerates missing values.
    static func attributes(of tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var i = tag.startIndex
        // Skip "<img".
        if tag.lowercased().hasPrefix("<img") {
            i = tag.index(i, offsetBy: 4)
        }
        func skipSpace() {
            while i < tag.endIndex, tag[i].isWhitespace || tag[i] == "/" { i = tag.index(after: i) }
        }
        while i < tag.endIndex {
            skipSpace()
            guard i < tag.endIndex, tag[i] != ">" else { break }
            let ns = i
            while i < tag.endIndex, tag[i].isLetter || tag[i].isNumber || tag[i] == "-" || tag[i] == "_" || tag[i] == ":" {
                i = tag.index(after: i)
            }
            let name = String(tag[ns ..< i]).lowercased()
            guard !name.isEmpty else {
                // Junk char (e.g. `?`): skip one, keep scanning.
                i = tag.index(after: i)
                continue
            }
            skipSpace()
            var value = ""
            if i < tag.endIndex, tag[i] == "=" {
                i = tag.index(after: i)
                skipSpace()
                if i < tag.endIndex, tag[i] == "\"" || tag[i] == "'" {
                    let q = tag[i]
                    i = tag.index(after: i)
                    let vs = i
                    while i < tag.endIndex, tag[i] != q { i = tag.index(after: i) }
                    value = String(tag[vs ..< i])
                    if i < tag.endIndex { i = tag.index(after: i) }
                } else {
                    let vs = i
                    while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != ">", tag[i] != "\"", tag[i] != "'" {
                        i = tag.index(after: i)
                    }
                    value = String(tag[vs ..< i])
                }
            }
            attrs[name] = value
        }
        return attrs
    }

    /// Emoticon iff explicit w/h both ≤ 32, an emoticon marker attr, or a
    /// `(code)` alt. Percent/other non-integer sizes never count as small.
    static func isEmoticonTag(_ attrs: [String: String]) -> Bool {
        if let w = attrs["width"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           let h = attrs["height"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           w <= 32, h <= 32
        {
            return true
        }
        for k in ["class", "itemtype", "type", "emoticon"] {
            if let v = attrs[k]?.lowercased(), v.contains("emoticon") { return true }
        }
        if let alt = attrs["alt"]?.trimmingCharacters(in: .whitespaces),
           alt.count >= 3, alt.hasPrefix("("), alt.hasSuffix(")")
        {
            return true
        }
        return false
    }

    // MARK: - Emoji (unicode native + Teams/Skype `(code)` shortcodes)

    /// Classic Teams/Skype picker shortcuts. Unknown codes pass through
    /// untouched (never mangle prose like `(see note)`).
    public static let emojiShortcodes: [String: String] = [
        "smile": "🙂", "bigsmile": "😁", "laugh": "😄", "wink": "😉",
        "sad": "😞", "cry": "😢", "tears": "😂", "angry": "😠",
        "cool": "😎", "nerd": "🤓", "surprised": "😮", "shock": "😲",
        "confused": "😕", "thinking": "🤔", "kiss": "😘", "sleepy": "😴",
        "sleep": "😴", "sick": "🤢", "devil": "😈", "angel": "😇",
        "ghost": "👻", "skull": "💀", "clown": "🤡",
        "heart": "❤️", "hearts": "💕", "brokenheart": "💔", "like": "👍",
        "thumbsup": "👍", "y": "👍", "dislike": "👎", "thumbsdown": "👎",
        "n": "👎", "clap": "👏", "pray": "🙏", "muscle": "💪",
        "handshake": "🤝", "wave": "👋", "eyes": "👀", "fire": "🔥",
        "star": "⭐", "check": "✅", "party": "🥳", "tada": "🎉",
        "gift": "🎁", "cake": "🎂", "coffee": "☕", "beer": "🍺",
        "rocket": "🚀", "sun": "☀️", "moon": "🌙", "rainbow": "🌈",
        "bell": "🔔", "dance": "💃", "punch": "👊", "fistbump": "🤜",
    ]

    /// What the bubble shows: `content` with `(code)` shortcodes expanded to
    /// unicode. Native unicode passes through. Backtick spans are left
    /// alone, so `` `(smile)` `` stays literal.
    public static func renderText(for message: ChatMessage) -> String {
        expandShortcodes(message.content)
    }

    public static func expandShortcodes(_ text: String) -> String {
        // Exclusion ranges: backtick spans widened to swallow the ticks.
        let excl: [Range<String.Index>] = backtickSpans(in: text).map { r in
            text.index(before: r.lowerBound) ..< text.index(after: r.upperBound)
        }
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        for r in excl {
            out += expandSegment(String(text[cursor ..< r.lowerBound]))
            out += text[r]
            cursor = r.upperBound
        }
        out += expandSegment(String(text[cursor...]))
        return out
    }

    /// One `(code)` pass over code-free text. Case-insensitive lookup.
    static func expandSegment(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "(" else { out.append(s[i]); i = s.index(after: i); continue }
            var j = s.index(after: i)
            var count = 0
            while j < s.endIndex, count < 20, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == "+" || s[j] == "-" {
                j = s.index(after: j); count += 1
            }
            if j < s.endIndex, s[j] == ")", count > 0,
               let emoji = emojiShortcodes[String(s[s.index(after: i) ..< j]).lowercased()]
            {
                out += emoji
                i = s.index(after: j)
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
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
