// TeamsTabsTests.swift — om-h4-tabs lane: wire decode, target mapping, store open.
import Foundation
import XCTest

@testable import OstMacCore

@MainActor
final class TeamsTabsTests: XCTestCase {
    nonisolated static func tabsJSON() -> TabsResponse {
        let json = """
            {"ok":true,"channel_id":"19:abc@thread.tacv2","tabs":[\
            {"id":"tab-posts","name":"Posts","app_id":null,\
            "content_url":null,"website_url":null},\
            {"id":"tab-files","name":"Files",\
            "app_id":"com.microsoft.teamspace.tab.files.sharepoint",\
            "content_url":null,"website_url":null},\
            {"id":"tab-notes","name":"Notes","app_id":"0d820ecd-def2-4297-a09a-912c7e06f45b",\
            "content_url":null,\
            "website_url":"https://example.sharepoint.com/notes"},\
            {"id":"tab-web","name":"Dashboard",\
            "app_id":"com.example.dashboard",\
            "content_url":"https://example.com/app","website_url":null}]}
            """
        return try! decodeOrThrow(TabsResponse.self, from: Data(json.utf8))
    }

    func waitFor(_ what: String, _ cond: @escaping () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testDecodeTabs() {
        let response = Self.tabsJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.tabs.count, 4)
        XCTAssertEqual(response.tabs[0].id, "tab-posts")
        XCTAssertEqual(response.tabs[1].name, "Files")
        XCTAssertEqual(
            response.tabs[1].appID, "com.microsoft.teamspace.tab.files.sharepoint")
        XCTAssertEqual(
            response.tabs[3].contentURL, "https://example.com/app")
    }

    func testTargetMapping() {
        let tabs = Self.tabsJSON().tabs
        XCTAssertEqual(tabs[0].target, .chat)
        XCTAssertEqual(tabs[1].target, .shared)
        XCTAssertEqual(tabs[2].target, .notes)
        XCTAssertEqual(tabs[3].target, .web(URL(string: "https://example.com/app")!))
    }

    func testIsChannelID() {
        XCTAssertTrue(ChannelTabsStore.isChannelID("19:abc@thread.tacv2"))
        XCTAssertFalse(ChannelTabsStore.isChannelID("19:abc@thread.v2"))
        XCTAssertFalse(ChannelTabsStore.isChannelID("demo"))
        XCTAssertFalse(ChannelTabsStore.isChannelID(""))
    }

    func testOpenReplacesTabs() async throws {
        let resp = Self.tabsJSON()
        let store = ChannelTabsStore(list: { _ in resp })
        store.open(channelID: "19:abc@thread.tacv2")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.tabs.count, 4)
        XCTAssertEqual(store.channelID, "19:abc@thread.tacv2")
    }

    /// om-nrecon-mopup: tab chips render on the native bezel
    /// (SwiftUI styles are not runtime-introspectable, so the
    /// conversion is pinned statically per NativeControlsTests).
    func testChipUsesNativeBezel() throws {
        // .../swift/Tests/OstMacCoreTests/TeamsTabsTests.swift.
        var url = URL(fileURLWithPath: #filePath, isDirectory: false)
        url.deleteLastPathComponent() // file
        url.deleteLastPathComponent() // OstMacCoreTests
        url.deleteLastPathComponent() // Tests
        url.appendPathComponent("Sources/OstMacCore/TeamsTabsView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            text.contains(".buttonStyle(.borderedProminent)"),
            "highlighted chip must use the native prominent bezel")
        XCTAssertTrue(
            text.contains(".buttonStyle(.bordered)"),
            "chip must use the native bordered bezel")
        XCTAssertTrue(
            text.contains(".controlSize(.small)"),
            "chip must keep small scale on the native bezel")
        XCTAssertFalse(
            text.contains(".clipShape(Capsule())"),
            "custom capsule bezel must be gone")
        XCTAssertFalse(
            text.contains(".buttonStyle(.plain)"),
            "plain custom-drawn chip style must be gone")
    }

    func testOpenErrorSurfaces() async throws {
        let store = ChannelTabsStore(list: { _ in
            throw CoreCallError.failed("nope")
        })
        store.open(channelID: "19:abc@thread.tacv2")
        try await waitFor("error") {
            if case .error = store.state { return true }
            return false
        }
        XCTAssertTrue(store.tabs.isEmpty)
    }
}
