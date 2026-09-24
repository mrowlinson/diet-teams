// AdaptiveCard.swift — om-jc-cards lane: Adaptive Card renderer core.
//
// Model: shallow parse of the Adaptive Card elements Teams bots post
// (TextBlock / FactSet / Image / Container / ColumnSet, one nesting
// level) plus Action.OpenUrl. Submit, inputs, Execute, and unknown
// actions are OUT of scope: cards carrying them set `needsFallback`
// and the bubble keeps the BotPostRows fallback row alongside the
// rendered card.
//
// Entry: `AdaptiveCard.cards(fromRaw:)` mines card JSON from the same
// `raw ?? content` string the posts path reads. Shapes (all real):
//   - bare card: {"type":"AdaptiveCard","body":[...],"actions":[...]}
//   - attachment envelope: {"contentType":"...card.adaptive","content":{...}}
//   - message envelope: {"attachments":[{...envelope...}]}
import DietDesign
import Foundation
import SwiftUI

/// One parsed Adaptive Card. Shallow: containers/columns nest one
/// level (deeper elements drop); inputs never parse (fallback signal).
public struct AdaptiveCard: Sendable, Equatable {
    // MARK: - Elements

    public struct TextBlock: Sendable, Equatable {
        public enum Size: String, Sendable { case small, `default`, medium, large, extraLarge }
        public enum Weight: String, Sendable { case lighter, `default`, bolder }
        public enum Color: String, Sendable {
            case `default`, dark, light, accent, good, attention, warning
        }

        public let text: String
        public let size: Size
        public let weight: Weight
        public let color: Color
        public let isSubtle: Bool
        public let wrap: Bool

        public init(
            text: String, size: Size = .default, weight: Weight = .default,
            color: Color = .default, isSubtle: Bool = false, wrap: Bool = false
        ) {
            self.text = text
            self.size = size
            self.weight = weight
            self.color = color
            self.isSubtle = isSubtle
            self.wrap = wrap
        }
    }

    public struct Fact: Sendable, Equatable {
        public let title: String
        public let value: String
        public init(title: String, value: String) {
            self.title = title
            self.value = value
        }
    }

    public struct CardImage: Sendable, Equatable {
        public let url: String
        public let altText: String
        public init(url: String, altText: String = "") {
            self.url = url
            self.altText = altText
        }
    }

    public enum Element: Sendable, Equatable {
        case text(TextBlock)
        case facts([Fact])
        case image(CardImage)
        /// Shallow container: leaves only (no nested containers).
        case container([Element])
        /// Shallow column set: each column holds leaves only.
        case columns([[Element]])
    }

    public struct OpenURLAction: Sendable, Equatable {
        public let title: String
        public let url: String
        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }
    }

    public let body: [Element]
    public let actions: [OpenURLAction]
    /// True when the payload carried Submit/inputs/Execute/unknown
    /// actions: the bubble keeps the fallback BotPostRows row too.
    public let needsFallback: Bool

    public init(body: [Element], actions: [OpenURLAction] = [], needsFallback: Bool = false) {
        self.body = body
        self.actions = actions
        self.needsFallback = needsFallback
    }

    // MARK: - Caps (hostile-blob bounds, same spirit as maxBotRows)

    static let maxBody = 20
    static let maxFacts = 20
    static let maxActions = 6
    static let maxColumns = 6
    static let maxText = 2000

    /// Teams/Graph content type for an Adaptive Card attachment.
    static let adaptiveContentType = "application/vnd.microsoft.card.adaptive"

    // MARK: - Mining

    /// Cards for one message: envelope shapes unwrapped to bare card
    /// objects, each parsed shallow. Anything else yields no cards.
    public static func cards(fromRaw raw: String?) -> [AdaptiveCard] {
        guard let raw,
              MessageRender.looksLikeJSONObject(raw),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        return cardObjects(from: json).compactMap(parse(card:)).prefix(10).map { $0 }
    }

    /// Bare card dicts from any envelope shape: message envelope
    /// attachments[], single attachment envelope content, or the
    /// object itself when it already is a card.
    static func cardObjects(from json: Any) -> [Any] {
        if let top = json as? [String: Any] {
            if let attachments = top["attachments"] as? [Any] {
                return attachments.compactMap { attachmentContent($0) }
            }
            if let content = attachmentContent(json) { return [content] }
            if isCardObject(top) { return [top] }
            return []
        }
        return []
    }

    /// The card object inside one attachment envelope, or nil when the
    /// content type is not adaptive (foreign attachments stay out).
    static func attachmentContent(_ value: Any) -> Any? {
        guard let obj = value as? [String: Any],
              let type = obj["contentType"] as? String,
              type.lowercased() == adaptiveContentType,
              let content = obj["content"]
        else { return nil }
        return content
    }

    static func isCardObject(_ obj: [String: Any]) -> Bool {
        (obj["type"] as? String)?.lowercased() == "adaptivecard"
    }

    // MARK: - Parse

    /// One bare card object -> model. Nil when nothing renderable
    /// parsed (the bubble placeholder owns such payloads).
    static func parse(card value: Any) -> AdaptiveCard? {
        guard let obj = value as? [String: Any], isCardObject(obj) else { return nil }
        var fallback = false
        let body = ((obj["body"] as? [Any]) ?? []).prefix(maxBody).compactMap {
            parseElement($0, nested: false, fallback: &fallback)
        }
        var actions: [OpenURLAction] = []
        for raw in ((obj["actions"] as? [Any]) ?? []).prefix(maxActions) {
            parseAction(raw, actions: &actions, fallback: &fallback)
        }
        // ActionSet elements may carry link actions too (shallow).
        for raw in ((obj["body"] as? [Any]) ?? []).prefix(maxBody) {
            if let el = raw as? [String: Any],
               (el["type"] as? String)?.lowercased() == "actionset"
            {
                for sub in ((el["actions"] as? [Any]) ?? []).prefix(maxActions) {
                    parseAction(sub, actions: &actions, fallback: &fallback)
                }
            }
        }
        guard !body.isEmpty || !actions.isEmpty else { return nil }
        return AdaptiveCard(body: body, actions: actions, needsFallback: fallback)
    }

    /// One body element. Nested (inside Container/Column): leaves only;
    /// deeper containers/sets drop. Input.* marks fallback, never parses.
    static func parseElement(_ value: Any, nested: Bool, fallback: inout Bool) -> Element? {
        guard let obj = value as? [String: Any],
              let type = (obj["type"] as? String)?.lowercased()
        else { return nil }
        switch type {
        case "textblock":
            guard let text = nonEmptyString(obj["text"]) else { return nil }
            return .text(TextBlock(
                text: String(text.prefix(maxText)),
                size: size(of: obj), weight: weight(of: obj),
                color: color(of: obj),
                isSubtle: obj["isSubtle"] as? Bool ?? false,
                wrap: obj["wrap"] as? Bool ?? false))
        case "image":
            guard let url = nonEmptyString(obj["url"]) else { return nil }
            return .image(CardImage(
                url: url, altText: (obj["altText"] as? String ?? "")))
        case "factset":
            let facts = ((obj["facts"] as? [Any]) ?? []).prefix(maxFacts).compactMap { raw -> Fact? in
                guard let f = raw as? [String: Any],
                      let title = nonEmptyString(f["title"]),
                      let value = nonEmptyString(f["value"])
                else { return nil }
                return Fact(
                    title: String(title.prefix(maxText)),
                    value: String(value.prefix(maxText)))
            }
            return facts.isEmpty ? nil : .facts(facts)
        case "container":
            guard !nested else { return nil }
            let items = ((obj["items"] as? [Any]) ?? []).prefix(maxBody).compactMap {
                parseElement($0, nested: true, fallback: &fallback)
            }
            return .container(items)
        case "columnset":
            guard !nested else { return nil }
            let cols = ((obj["columns"] as? [Any]) ?? []).prefix(maxColumns).map { raw -> [Element] in
                guard let col = raw as? [String: Any] else { return [] }
                return ((col["items"] as? [Any]) ?? []).prefix(maxBody).compactMap {
                    parseElement($0, nested: true, fallback: &fallback)
                }
            }
            return .columns(cols)
        case "actionset":
            // Actions mined in parse(card:); no body element.
            return nil
        default:
            // Input.* and every unknown element: fallback signal.
            fallback = true
            return nil
        }
    }

    /// One action dict: OpenUrl adopted (http(s) only), everything else
    /// (Submit/Execute/unknown) marks fallback.
    static func parseAction(_ value: Any, actions: inout [OpenURLAction], fallback: inout Bool) {
        guard let obj = value as? [String: Any],
              let type = (obj["type"] as? String)?.lowercased()
        else { return }
        guard type == "action.openurl" else {
            fallback = true
            return
        }
        guard let url = nonEmptyString(obj["url"] ?? obj["uri"]),
              AdaptiveCardView.linkTarget(for: url) != nil
        else { return }
        let title = nonEmptyString(obj["title"]) ?? url
        actions.append(OpenURLAction(
            title: String(title.prefix(140)), url: url))
    }

    // MARK: - Field readers

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !s.isEmpty
        else { return nil }
        return s
    }

    static func size(of obj: [String: Any]) -> TextBlock.Size {
        switch (obj["size"] as? String)?.lowercased() {
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "extralarge": return .extraLarge
        default: return .default
        }
    }

    static func weight(of obj: [String: Any]) -> TextBlock.Weight {
        switch (obj["weight"] as? String)?.lowercased() {
        case "lighter": return .lighter
        case "bolder": return .bolder
        default: return .default
        }
    }

    static func color(of obj: [String: Any]) -> TextBlock.Color {
        switch (obj["color"] as? String)?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        case "accent": return .accent
        case "good": return .good
        case "attention": return .attention
        case "warning": return .warning
        default: return .default
        }
    }

    // MARK: - Copy text

    /// Plain lines for Copy: text blocks, `title — value` fact rows,
    /// image alts, and `title — url` action lines. No raw JSON.
    public var copyLines: [String] {
        var out: [String] = []
        for el in body { appendCopy(of: el, to: &out) }
        for a in actions { out.append("\(a.title) — \(a.url)") }
        return out
    }

    private func appendCopy(of el: Element, to out: inout [String]) {
        switch el {
        case let .text(t): out.append(t.text)
        case let .facts(fs):
            for f in fs { out.append("\(f.title) — \(f.value)") }
        case let .image(img):
            out.append(img.altText.isEmpty ? img.url : img.altText)
        case let .container(items):
            for i in items { appendCopy(of: i, to: &out) }
        case let .columns(cols):
            for col in cols { for i in col { appendCopy(of: i, to: &out) } }
        }
    }
}

/// Bubble posts-path gating (pure, testable): cards render when any
/// parse; fallback rows render when posts exist AND (no cards, or some
/// card needs fallback for its Submit/inputs/Execute surface).
public enum MessageBubbleState {
    public static func cards(for message: ChatMessage) -> [AdaptiveCard] {
        AdaptiveCard.cards(fromRaw: message.raw ?? message.content)
    }

    public static func shouldShowCards(for message: ChatMessage) -> Bool {
        !cards(for: message).isEmpty
    }

    public static func shouldShowFallbackRows(for message: ChatMessage) -> Bool {
        let posts = MessageRender.botPosts(fromRaw: message.raw ?? message.content)
        guard !posts.isEmpty else { return false }
        let cards = cards(for: message)
        return cards.isEmpty || cards.contains(where: \.needsFallback)
    }
}

/// One rendered Adaptive Card: styled text, fact rows, card images,
/// OpenUrl buttons as http(s)-only Links. Submit/inputs/Execute have
/// no control here — the fallback row covers them.
public struct AdaptiveCardView: View {
    public let card: AdaptiveCard
    public let messageID: String

    public init(card: AdaptiveCard, messageID: String) {
        self.card = card
        self.messageID = messageID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            ForEach(Array(card.body.enumerated()), id: \.offset) { _, el in
                elementView(el)
            }
            ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                if let target = Self.linkTarget(for: action.url) {
                    Link(destination: target) {
                        Text(action.title).underline()
                    }
                    .font(DietType.body)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(DietSpace.xs)
        .background(
            DietColor.cardColor,
            in: RoundedRectangle(cornerRadius: DietRadius.card))
    }

    @ViewBuilder
    private func elementView(_ el: AdaptiveCard.Element) -> some View {
        switch el {
        case let .container(items):
            VStack(alignment: .leading, spacing: DietSpace.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, sub in
                    leafView(sub)
                }
            }
        case let .columns(cols):
            HStack(alignment: .top, spacing: DietSpace.sm) {
                ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                    VStack(alignment: .leading, spacing: DietSpace.xs) {
                        ForEach(Array(col.enumerated()), id: \.offset) { _, sub in
                            leafView(sub)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        default:
            leafView(el)
        }
    }

    /// Leaf renderer (no nesting): the parser guarantees containers
    /// and columns hold leaves only, so this never recurses.
    @ViewBuilder
    private func leafView(_ el: AdaptiveCard.Element) -> some View {
        switch el {
        case let .text(t): textView(t)
        case let .facts(fs): factsView(fs)
        case let .image(img):
            RemoteImage(url: img.url, messageID: messageID, alt: img.altText)
        case .container, .columns:
            EmptyView()
        }
    }

    private func textView(_ t: AdaptiveCard.TextBlock) -> some View {
        Text(t.text)
            .font(Self.fontFor(t))
            .foregroundStyle(Self.colorFor(t))
            .lineLimit(t.wrap ? nil : 3)
    }

    private func factsView(_ facts: [AdaptiveCard.Fact]) -> some View {
        VStack(alignment: .leading, spacing: DietSpace.xxs) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .top, spacing: DietSpace.sm) {
                    Text(f.title)
                        .font(DietType.caption1).bold()
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .frame(maxWidth: 110, alignment: .leading)
                    Text(f.value)
                        .font(DietType.body)
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Styling

    static func fontFor(_ t: AdaptiveCard.TextBlock) -> Font {
        let base: Font = switch t.size {
        case .small: DietType.caption1
        case .default: DietType.body
        case .medium: .system(size: 17)
        case .large: .title3
        case .extraLarge: .title2
        }
        return switch t.weight {
        case .lighter: base.weight(.light)
        case .default: base
        case .bolder: base.bold()
        }
    }

    static func colorFor(_ t: AdaptiveCard.TextBlock) -> Color {
        if t.isSubtle { return DietColor.textSecondaryColor }
        return switch t.color {
        case .default: DietColor.textPrimaryColor
        case .dark: DietColor.textPrimaryColor
        case .light: DietColor.textSecondaryColor
        case .accent: Color.accentColor
        case .good: Color(nsColor: DietColor.success)
        case .attention: Color(nsColor: DietColor.danger)
        case .warning: Color(nsColor: DietColor.warning)
        }
    }

    /// Parsed http(s) link target, or nil (same rule as BotPostRows).
    public static func linkTarget(for raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }
}
