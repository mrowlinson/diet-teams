// NativeControlsTests — om-native-convert: NATIVE UI ONLY rule.
// SwiftUI styles are not runtime-introspectable, so the rule is
// pinned statically: no custom-drawn control rendering in Sources.
// Diet tokens (type/color) stay; control chrome must be system.
import Foundation
import XCTest

final class NativeControlsTests: XCTestCase {
    /// swift/Sources dir, derived from this file's compile-time path:
    /// .../swift/Tests/DietDesignTests/NativeControlsTests.swift.
    private static func sourcesDir() -> URL {
        var url = URL(fileURLWithPath: #filePath, isDirectory: false)
        url.deleteLastPathComponent() // file
        url.deleteLastPathComponent() // DietDesignTests
        url.deleteLastPathComponent() // Tests
        return url.appendingPathComponent("Sources", isDirectory: true)
    }

    private static func swiftFiles() throws -> [(name: String, text: String)] {
        let dir = sourcesDir()
        let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil)!
        var out: [(name: String, text: String)] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            out.append((file.lastPathComponent, text))
        }
        return out
    }

    /// Files containing `token`, minus allowlisted basenames.
    private func holders(
        _ token: String, allowing: Set<String> = []
    ) throws -> [String] {
        try Self.swiftFiles()
            .filter { $0.text.contains(token) }
            .map(\.name)
            .filter { !allowing.contains($0) }
            .sorted()
    }

    func testNoCustomButtonStyles() throws {
        // Call sites must use system styles (.bordered,
        // .borderedProminent, .borderless, .link, .plain).
        for token in [".dietPrimary", ".dietSecondary", ".dietDestructive"] {
            XCTAssertEqual(
                try holders(token), [],
                "\(token) custom rendering remains")
        }
        for token in [
            "DietPrimaryButtonStyle", "DietSecondaryButtonStyle",
            "DietDestructiveButtonStyle",
        ] {
            XCTAssertEqual(
                try holders(token), [],
                "\(token) custom type remains")
        }
    }

    func testNoPlainTextFieldWells() throws {
        // Bare-field exceptions: fields with NO custom chrome (no
        // well, no clip, no focus overlay). Palette/popover headers
        // use borderless language; the edit sheet's vertical-axis
        // field has no bezel style (.roundedBorder clips it to one
        // line, TextEditor renders blank in the sheet) so it stays
        // a bare multiline field.
        let allowing: Set<String> = [
            "ConversationView.swift", "JumpPaletteView.swift",
            "MentionCompose.swift",
        ]
        XCTAssertEqual(
            try holders(".textFieldStyle(.plain)", allowing: allowing),
            [],
            ".plain text field with custom chrome remains")
        // The allowlisted files still render their main fields
        // consistently: the conversation send box uses the plain+well
        // recipe (a still-native TextField with well fill + divider
        // stroke). The roundedBorder bezel will not stretch to the
        // 48pt 2-line height, so it cannot carry the send box
        // (pixel-verified, see COMPOSER-2LINE-PROOF.md).
        let files = try Self.swiftFiles()
        let conv = try XCTUnwrap(
            files.first(where: { $0.name == "ConversationView.swift" }),
            "ConversationView.swift missing")
        XCTAssertTrue(
            conv.text.contains(".textFieldStyle(.plain)"),
            "conversation send box must keep the plain+well recipe")
        XCTAssertTrue(
            conv.text.contains("DietColor.wellColor"),
            "conversation send box must keep the well fill")
        XCTAssertTrue(
            conv.text.contains(".plainFocusRing()"),
            "conversation send box must keep the focus ring")
    }

    func testFieldComponentsRenderNative() throws {
        // DietField internals: system bezels only, no wells, no
        // hand-drawn focus rings (the system ring carries focus).
        let files = try Self.swiftFiles()
        let field = try XCTUnwrap(
            files.first(where: { $0.name == "DietField.swift" }),
            "DietField.swift missing")
        XCTAssertTrue(
            field.text.contains(".textFieldStyle(.roundedBorder)"),
            "DietField must use the system bezel")
        XCTAssertFalse(
            field.text.contains("wellColor"),
            "DietField must not paint wells")
        XCTAssertFalse(
            field.text.contains("RoundedRectangle"),
            "DietField must not draw chrome")
        XCTAssertFalse(
            field.text.contains(".dietPrimary"),
            "DietComposer send must be a system style")
    }

    func testSharedComponentsRenderNative() throws {
        // om-shared-diet: single-point converts. Shared bodies
        // must compose native APIs; call sites stay untouched.
        let files = try Self.swiftFiles()
        let divider = try XCTUnwrap(
            files.first(where: { $0.name == "DietDivider.swift" }),
            "DietDivider.swift missing")
        XCTAssertTrue(
            divider.text.contains("Divider()"),
            "DietDividerH/V + DietSeamH must render Divider()")
        XCTAssertFalse(
            divider.text.contains("DietColor.dividerColor.frame"),
            "dividers must not paint custom 1px rects")
        let states = try XCTUnwrap(
            files.first(where: { $0.name == "DietStates.swift" }),
            "DietStates.swift missing")
        XCTAssertTrue(
            states.text.contains("ContentUnavailableView"),
            "DietEmptyState must render ContentUnavailableView")
        let layout = try XCTUnwrap(
            files.first(where: { $0.name == "DietLayout.swift" }),
            "DietLayout.swift missing")
        XCTAssertTrue(
            layout.text.contains("GroupBox"),
            "DietCard/DietSectionCard must render GroupBox")
        XCTAssertTrue(
            layout.text.contains("NavigationSplitView"),
            "DietColumns must render NavigationSplitView")
        XCTAssertFalse(
            layout.text.contains("RoundedRectangle(cornerRadius: DietRadius.card)"),
            "cards must not draw custom chrome")
    }

    func testButtonComponentsRenderNative() throws {
        // DietButton internals: no custom style structs, icon
        // button on the system borderless style (native hover),
        // no hand-painted hover wells.
        let files = try Self.swiftFiles()
        let buttons = try XCTUnwrap(
            files.first(where: { $0.name == "DietButton.swift" }),
            "DietButton.swift missing")
        XCTAssertFalse(
            buttons.text.contains("wellColor"),
            "DietButton must not paint wells")
        XCTAssertFalse(
            buttons.text.contains(": ButtonStyle"),
            "custom ButtonStyle types must be gone")
        XCTAssertTrue(
            buttons.text.contains(".buttonStyle(.borderless)"),
            "DietIconButton must use the system style")
    }
}
