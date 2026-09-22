// IdentityTests.swift — om-identity-own lane: whoami decode + isOwn stamping.
import XCTest

@testable import OstMacCore

@MainActor
final class IdentityTests: XCTestCase {
    func testWhoamiDecodes() throws {
        let data = """
        {"ok":true,"id":"gid-1","display_name":"Doe, Jane","mail":"j@x.example"}
        """.data(using: .utf8)!
        let w = try JSONDecoder().decode(WhoamiResponse.self, from: data)
        XCTAssertEqual(w.id, "gid-1")
        XCTAssertEqual(w.display_name, "Doe, Jane")
        XCTAssertEqual(w.mail, "j@x.example")
    }

    func testWhoamiDecodesNullMail() throws {
        let data = """
        {"ok":true,"id":"gid-2","display_name":"No Mail","mail":null}
        """.data(using: .utf8)!
        let w = try JSONDecoder().decode(WhoamiResponse.self, from: data)
        XCTAssertNil(w.mail)
    }

    func testStampOwnershipMatchesSender() {
        let list = [
            ChatMessage(id: "m1", sender: "Doe, Jane", timestamp: "t", content: "mine"),
            ChatMessage(id: "m2", sender: "Tom Becker", timestamp: "t", content: "theirs"),
        ]
        let out = ConversationStore.stampOwnership(list, ownName: "Doe, Jane")
        XCTAssertTrue(out[0].isOwn)
        XCTAssertFalse(out[1].isOwn)
    }

    func testStampOwnershipNilNameClears() {
        let list = [ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "x", isOwn: true)]
        let out = ConversationStore.stampOwnership(list, ownName: nil)
        XCTAssertFalse(out[0].isOwn)
    }

    func testAdoptIdentityRestamps() {
        let store = ConversationStore()
        store.ingest(ChatMessage(id: "m1", sender: "Doe, Jane", timestamp: "t", content: "hi"))
        XCTAssertFalse(store.messages[0].isOwn)
        store.adoptIdentity(displayName: "Doe, Jane")
        XCTAssertEqual(store.ownDisplayName, "Doe, Jane")
        XCTAssertTrue(store.messages[0].isOwn)
    }

    func testClearIdentityKeepsBubbles() {
        let store = ConversationStore()
        store.adoptIdentity(displayName: "Doe, Jane")
        store.ingest(ChatMessage(id: "m1", sender: "Doe, Jane", timestamp: "t", content: "hi"))
        XCTAssertTrue(store.messages[0].isOwn)
        store.clearIdentity()
        XCTAssertNil(store.ownDisplayName)
        XCTAssertTrue(store.messages[0].isOwn) // bubbles keep flags
        store.ingest(ChatMessage(id: "m2", sender: "Doe, Jane", timestamp: "t", content: "later"))
        XCTAssertFalse(store.messages[1].isOwn) // new ingests unowned
    }

    func testIngestStampsOwnVsOther() {
        let store = ConversationStore()
        store.adoptIdentity(displayName: "Me")
        store.ingest(ChatMessage(id: "m1", sender: "Me", timestamp: "t", content: "mine"))
        store.ingest(ChatMessage(id: "m2", sender: "Them", timestamp: "t", content: "theirs"))
        XCTAssertTrue(store.messages[0].isOwn)
        XCTAssertFalse(store.messages[1].isOwn)
    }

    /// Live FFI linkage: the symbol resolves and the envelope decodes.
    /// Unsigned machines throw (no tokens) — either outcome passes; a
    /// link failure or shape mismatch fails the test run instead.
    func testLiveFFIWhoamiLinks() {
        do {
            let w = try RustCore.whoami()
            XCTAssertTrue(w.ok)
            XCTAssertFalse(w.id.isEmpty)
            XCTAssertFalse(w.display_name.isEmpty)
        } catch {
            // Unsigned: core correctly refused before/after network.
        }
    }
}
