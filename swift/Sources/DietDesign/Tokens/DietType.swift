// DietType.swift — SF type scale. Semantic styles only; no raw sizes.
import SwiftUI

/// App type scale on SF. Names follow usage, values follow the
/// HIG scale (largeTitle 34 … caption2 11).
public enum DietType {
    public static let largeTitle = Font.largeTitle
    public static let title1 = Font.title
    public static let title2 = Font.title2
    public static let title3 = Font.title3
    public static let headline = Font.headline
    public static let body = Font.body
    public static let callout = Font.callout
    public static let subheadline = Font.subheadline
    public static let footnote = Font.footnote
    public static let caption1 = Font.caption
    public static let caption2 = Font.caption2

    /// Monospaced digits for timestamps, counts, versions.
    public static let captionMono = Font.caption.monospacedDigit()
    public static let footnoteMono = Font.footnote.monospacedDigit()

    /// Ordered scale for tests/showcase (largest first).
    public static let scale: [(name: String, font: Font)] = [
        ("largeTitle", .largeTitle),
        ("title1", .title),
        ("title2", .title2),
        ("title3", .title3),
        ("headline", .headline),
        ("body", .body),
        ("callout", .callout),
        ("subheadline", .subheadline),
        ("footnote", .footnote),
        ("caption1", .caption),
        ("caption2", .caption2),
    ]
}
