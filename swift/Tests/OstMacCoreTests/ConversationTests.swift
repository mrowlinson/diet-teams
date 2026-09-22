// ConversationTests.swift — om-conv lane: upsert/edit semantics + FFI round-trip.
import XCTest

@testable import OstMacCore

@MainActor
final class ConversationTests: XCTestCase {
    func testUpsertAppendsNew() {
        let list = [ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi")]
        let out = ConversationStore.upsert(
            ChatMessage(id: "m2", sender: "B", timestamp: "t", content: "yo"), into: list)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].id, "m2")
    }

    func testUpsertUpdatesInPlace() {
        let list = [
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"),
            ChatMessage(id: "m2", sender: "B", timestamp: "t", content: "yo"),
        ]
        let out = ConversationStore.upsert(
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "EDITED"), into: list)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].content, "EDITED")
        XCTAssertEqual(out[1].content, "yo")
    }

    func testIngestEditedUnknownIdNoop() {
        let store = ConversationStore()
        store.ingest(ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"))
        store.ingestEdited(id: "nope", content: "x")
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].content, "hi")
        store.ingestEdited(id: "m1", content: "EDITED")
        XCTAssertEqual(store.messages[0].content, "EDITED")
    }

    func testDemoMode() {
        let store = ConversationStore.demo()
        XCTAssertTrue(store.messages.count >= 5)
        XCTAssertTrue(store.messages.contains { $0.isOwn })
        store.send(text: "local echo")
        XCTAssertEqual(store.messages.last?.content, "local echo")
        XCTAssertTrue(store.messages.last?.isOwn ?? false)
    }

    /// Live FFI round-trip through the linked staticlib: empty chat id is
    /// rejected by core before any network, Swift decodes the error envelope.
    func testLiveFFIEmptyChatIDThrows() {
        XCTAssertThrowsError(try RustCore.messages(chatID: ""))
        XCTAssertThrowsError(try RustCore.send(chatID: "19:x", text: "  "))
    }
}
