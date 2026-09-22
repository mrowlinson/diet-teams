// CatchUpTests.swift — om-catchup lane: OFF default, mock transport,
// prompt shape, threshold gate, endpoint join, transcript cap.
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        // Isolated persistence per test (never touches the real defaults).
        suite = "test-catchup-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func thread(_ n: Int) -> [ChatMessage] {
        (1 ... n).map {
            ChatMessage(
                id: "m\($0)", sender: "User \($0 % 3)",
                timestamp: "2026-09-22T09:0\($0 % 10):00Z",
                content: "message number \($0)")
        }
    }

    func testDefaultsOff() {
        let store = CatchUpStore(defaults: defaults)
        XCTAssertFalse(store.config.enabled)
        XCTAssertEqual(store.config.apiKey, "")
        XCTAssertEqual(store.state, .idle)
    }

    func testDisabledNeverCallsTransport() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let store = CatchUpStore(transport: mock, defaults: defaults)
        store.adopt(CatchUpConfig(enabled: false, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(mock.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.off.message))
    }

    func testMissingKeyFailsWithoutCalling() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let store = CatchUpStore(transport: mock, defaults: defaults)
        store.adopt(CatchUpConfig(enabled: true, apiKey: "  "))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(mock.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.missingKey.message))
    }

    func testEmptyThreadFailsWithoutCalling() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let store = CatchUpStore(transport: mock, defaults: defaults)
        store.adopt(CatchUpConfig(enabled: true, apiKey: "k"))
        await store.summarize(messages: [])
        XCTAssertTrue(mock.prompts.isEmpty)
        if case .failed = store.state {} else {
            XCTFail("expected .failed, got \(store.state)")
        }
    }

    func testMockSuccessLoadsText() async {
        let mock = CatchUpCannedTransport(stub: "TL;DR: standup happened.")
        let store = CatchUpStore(transport: mock, defaults: defaults)
        store.adopt(CatchUpConfig(enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(mock.prompts.count, 1)
        XCTAssertEqual(store.state, .loaded("TL;DR: standup happened."))
    }

    func testPromptCarriesTranscriptAndSections() async {
        let mock = CatchUpCannedTransport(stub: "ok")
        let store = CatchUpStore(transport: mock, defaults: defaults)
        store.adopt(CatchUpConfig(enabled: true, apiKey: "k"))
        let msgs = [
            ChatMessage(id: "m1", sender: "Priya", timestamp: "t", content: "ship the picker"),
            ChatMessage(id: "m2", sender: "Tom", timestamp: "t", content: "on it\nsecond line"),
        ]
        await store.summarize(messages: msgs)
        XCTAssertEqual(mock.prompts.count, 1)
        let prompt = mock.prompts[0]
        XCTAssertTrue(prompt.contains("TL;DR"))
        XCTAssertTrue(prompt.contains("Key points"))
        XCTAssertTrue(prompt.contains("Action items"))
        XCTAssertTrue(prompt.contains("Priya: ship the picker"))
        // Multiline content collapses to one transcript line.
        XCTAssertTrue(prompt.contains("Tom: on it second line"))
    }

    func testTransportErrorSurfacesFailed() async {
        struct Boom: Error {}
        let mock = CatchUpCannedTransport(stub: "", failure: Boom())
        let store = CatchUpStore(transport: mock, defaults: defaults)
        store.adopt(CatchUpConfig(enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        if case .failed = store.state {} else {
            XCTFail("expected .failed, got \(store.state)")
        }
    }

    func testThresholdGate() {
        XCTAssertFalse(CatchUp.shouldOffer(messageCount: CatchUp.threshold - 1))
        XCTAssertTrue(CatchUp.shouldOffer(messageCount: CatchUp.threshold))
        XCTAssertTrue(CatchUp.shouldOffer(messageCount: CatchUp.threshold + 100))
    }

    func testEndpointJoinsBaseURL() {
        XCTAssertEqual(
            CatchUp.endpoint(baseURL: "https://api.openai.com/v1"),
            "https://api.openai.com/v1/chat/completions")
        // Trailing slashes collapse to exactly one join slash.
        XCTAssertEqual(
            CatchUp.endpoint(baseURL: "http://localhost:1234/v1///"),
            "http://localhost:1234/v1/chat/completions")
    }

    func testTranscriptTailCap() {
        var msgs = thread(5)
        msgs.append(ChatMessage(
            id: "big", sender: "Spammer", timestamp: "t",
            content: String(repeating: "x", count: CatchUp.maxTranscriptChars + 500) + "TAILMARK"))
        let text = CatchUp.transcript(from: msgs)
        XCTAssertLessThanOrEqual(text.count, CatchUp.maxTranscriptChars)
        // Tail wins: newest content survives, oldest lines are dropped.
        XCTAssertTrue(text.contains("TAILMARK"))
        XCTAssertFalse(text.contains("message number 1"))
    }

    func testRequestBodyShape() throws {
        let data = CatchUp.requestBody(model: "m1", prompt: "hello")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "m1")
        let msgs = json?["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.count, 1)
        XCTAssertEqual(msgs?[0]["role"], "user")
        XCTAssertEqual(msgs?[0]["content"], "hello")
    }

    func testChatCompletionsDecode() throws {
        let data = """
        {"choices": [{"message": {"content": "TL;DR: ok"}}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        XCTAssertEqual(decoded.choices.first?.message.content, "TL;DR: ok")
    }

    func testConfigPersistsAcrossStores() {
        let a = CatchUpStore(defaults: defaults)
        a.adopt(CatchUpConfig(enabled: true, baseURL: "http://x/v1", model: "mm", apiKey: "kk"))
        let b = CatchUpStore(defaults: defaults)
        XCTAssertEqual(b.config, CatchUpConfig(
            enabled: true, baseURL: "http://x/v1", model: "mm", apiKey: "kk"))
    }
}
