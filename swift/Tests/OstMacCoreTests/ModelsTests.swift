// Bridge/parsing tests: decode fixtures exactly as the core emits them.
import XCTest

@testable import OstMacCore

final class ModelsTests: XCTestCase {
    func testStatusUnsigned() throws {
        let json = """
        {"ok":true,"signed_in":false,"tokens":{
        "aad":{"present":false,"expired":false},
        "refresh_present":false,
        "graph":{"present":false,"expired":false},
        "ic3":{"present":false,"expired":false},
        "recorder":{"present":false,"expired":false},
        "skype":{"present":false,"expired":false},
        "region_gtms_present":false}}
        """
        let st = try decodeOrThrow(
            StatusResponse.self, from: Data(json.utf8))
        XCTAssertFalse(st.signed_in)
        XCTAssertFalse(st.tokens.skype.present)
    }

    func testErrorEnvelopeThrows() {
        let json = """
        {"ok":false,"error":"chats","detail":"Token expired"}
        """
        XCTAssertThrowsError(
            try decodeOrThrow(ChatsResponse.self, from: Data(json.utf8))
        )
    }

    func testDeviceStart() throws {
        let json = """
        {"ok":true,"session":"dc-1-2",
        "verification_uri":"https://login.microsoft.com/device",
        "user_code":"ABC123","message":"m","expires_in":900,"interval":5}
        """
        let d = try decodeOrThrow(DeviceStart.self, from: Data(json.utf8))
        XCTAssertEqual(d.session, "dc-1-2")
        XCTAssertEqual(d.user_code, "ABC123")
    }

    func testDevicePollPendingAndComplete() throws {
        let p = try decodeOrThrow(
            DevicePoll.self,
            from: Data(#"{"ok":true,"status":"pending","interval":5}"#.utf8))
        XCTAssertEqual(p.status, "pending")
        XCTAssertEqual(p.interval, 5)
    }

    func testChatsDecode() throws {
        let json = """
        {"ok":true,"chats":[
        {"id":"19:a@thread","name":"Grp","is_group":true,
         "last_message_time":"t","last_message_sender":"s",
         "last_message_preview":"hi"}]}
        """
        let r = try decodeOrThrow(ChatsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.chats.count, 1)
        XCTAssertEqual(r.chats[0].chatId, "19:a@thread")
        XCTAssertTrue(r.chats[0].is_group)
    }

    func testTrouterEventsDecode() throws {
        let json = """
        {"ok":true,"events":[{"kind":"msg"},{"n":1},null,"x"]}
        """
        let r = try decodeOrThrow(TrouterPoll.self, from: Data(json.utf8))
        XCTAssertEqual(r.events.count, 4)
        XCTAssertTrue(r.events[0].value.contains("kind"))
    }
}
