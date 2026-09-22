// AppIdentityTests.swift — om-package lane: branding, account summary, demo rows.
import XCTest

import OstMacCore

final class AppIdentityTests: XCTestCase {
    func testIdentityValues() {
        XCTAssertEqual(AppIdentity.name, "OstMac")
        XCTAssertEqual(AppIdentity.bundleID, "dev.ostmac.OstMac")
        XCTAssertEqual(AppIdentity.version, "0.1.0")
        XCTAssertEqual(AppIdentity.minimumOS, "14.0")
    }

    nonisolated static func status(signedIn: Bool, slots: [Bool]) -> StatusResponse {
        precondition(slots.count == 7)
        func slot(_ present: Bool) -> String {
            #"{"present":\#(present ? "true" : "false"),"expired":false}"#
        }
        func boolean(_ v: Bool) -> String { v ? "true" : "false" }
        let json = #"{"ok":true,"signed_in":\#(boolean(signedIn)),"tokens":{"aad":\#(slot(slots[0])),"refresh_present":\#(boolean(slots[1])),"graph":\#(slot(slots[2])),"ic3":\#(slot(slots[3])),"recorder":\#(slot(slots[4])),"skype":\#(slot(slots[5])),"region_gtms_present":\#(boolean(slots[6]))}}"#
        return try! decodeOrThrow(StatusResponse.self, from: Data(json.utf8))
    }

    func testSummarizeSignedInAllTokens() {
        let info = AccountInfo.summarize(Self.status(signedIn: true, slots: [true, true, true, true, true, true, true]))
        XCTAssertTrue(info.signedIn)
        XCTAssertEqual(info.detail, "Signed in · tokens 7/7")
    }

    func testSummarizeSignedInPartialTokens() {
        let info = AccountInfo.summarize(Self.status(signedIn: true, slots: [false, true, false, false, false, true, false]))
        XCTAssertTrue(info.signedIn)
        XCTAssertEqual(info.detail, "Signed in · tokens 2/7")
    }

    func testSummarizeSignedOut() {
        let info = AccountInfo.summarize(Self.status(signedIn: false, slots: [false, false, false, false, false, false, false]))
        XCTAssertFalse(info.signedIn)
        XCTAssertEqual(info.detail, "Not signed in")
    }

    func testChatItemInit() {
        let c = ChatItem(chatId: "19:x", name: "Grp", is_group: true,
                         last_message_time: "2026-09-22T09:12:05Z",
                         last_message_sender: "Priya", last_message_preview: "hi")
        XCTAssertEqual(c.id, "19:x")
        XCTAssertEqual(c.name, "Grp")
        XCTAssertTrue(c.is_group)
        XCTAssertEqual(c.last_message_preview, "hi")
    }

    func testDemoChats() {
        XCTAssertEqual(DemoData.chats.count, 3)
        XCTAssertEqual(DemoData.chats[0].id, "demo")
        XCTAssertTrue(DemoData.chats.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(DemoData.chats.contains { $0.is_group })
        XCTAssertTrue(DemoData.chats.contains { !$0.is_group })
    }
}
