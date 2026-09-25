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

    func testSettingsSurfacesRenderNative() throws {
        // om-settings-convert: settings+modules CONVERT #1-4 —
        // LevelBar is a system ProgressView, planner toggle is a
        // system borderless button (no hand-drawn focus ring), and
        // calendar/contact rows are real Buttons (keyboard/focus
        // activation), not tap-gesture stacks.
        let files = try Self.swiftFiles()
        let av = try XCTUnwrap(
            files.first(where: { $0.name == "AvPanelView.swift" }),
            "AvPanelView.swift missing")
        XCTAssertTrue(
            av.text.contains(".progressViewStyle(.linear)"),
            "LevelBar must be a system linear ProgressView")
        XCTAssertFalse(
            av.text.contains("GeometryReader"),
            "LevelBar must not hand-draw its meter")
        let planner = try XCTUnwrap(
            files.first(where: { $0.name == "PlannerBrowser.swift" }),
            "PlannerBrowser.swift missing")
        XCTAssertTrue(
            planner.text.contains(".buttonStyle(.borderless)"),
            "planner toggle must use the system borderless style")
        XCTAssertFalse(
            planner.text.contains("plainFocusRing"),
            "planner toggle must not paint its own focus ring")
        let cal = try XCTUnwrap(
            files.first(where: { $0.name == "CalendarWeekView.swift" }),
            "CalendarWeekView.swift missing")
        XCTAssertFalse(
            cal.text.contains(".onTapGesture"),
            "calendar day column must be a Button, not a tap gesture")
        let contacts = try XCTUnwrap(
            files.first(where: { $0.name == "ContactsBrowser.swift" }),
            "ContactsBrowser.swift missing")
        XCTAssertFalse(
            contacts.text.contains(".onTapGesture"),
            "contact row must be a Button, not a tap gesture")
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
