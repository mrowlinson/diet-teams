// CatchUpSheetTests.swift — om-catchup-sheet-dismiss lane: every dismiss
// intent (Done, Esc, click-outside) closes the presentation AND resets
// the summary state; reopen always starts at .idle.
import SwiftUI
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpSheetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        // Isolated persistence per test (never touches the real defaults).
        suite = "test-catchup-sheet-\(UUID().uuidString)"
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

    /// Store parked in `.loaded` via the canned direct transport.
    /// Explicit direct provider: exclusive routing sends the default
    /// CLI provider to cliTransport always (see CatchUpFallbackTests),
    /// so the default config would park in the CLI canary instead.
    private func loadedStore() async -> CatchUpStore {
        let direct = CatchUpCannedTransport(stub: "TL;DR: standup happened.")
        let cli = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let store = CatchUpStore(
            transport: direct,
            cliTransport: cli,
            defaults: defaults, keyStore: CatchUpMemoryKeyStore())
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(direct.prompts.count, 1)
        XCTAssertTrue(cli.prompts.isEmpty)
        XCTAssertEqual(store.state, .loaded("TL;DR: standup happened."))
        return store
    }

    /// Store parked in `.failed` (disabled → off message, no transport).
    private func failedStore() async -> CatchUpStore {
        let store = CatchUpStore(
            transport: CatchUpCannedTransport(stub: "SHOULD NOT APPEAR"),
            cliTransport: CatchUpCannedTransport(stub: "SHOULD NOT APPEAR"),
            defaults: defaults, keyStore: CatchUpMemoryKeyStore())
        store.adopt(CatchUpConfig(enabled: false, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(store.state, .failed(CatchUpError.off.message))
        return store
    }

    func testOpenPresentsAndResetsState() async {
        let store = await failedStore()
        var isPresented = false
        // Binding over a local flag, standing in for the host's
        // `$showCatchUp` presentation binding.
        let presented = Binding(get: { isPresented }, set: { isPresented = $0 })
        CatchUpSheet.open(presented: presented, store: store)
        XCTAssertTrue(isPresented)
        XCTAssertEqual(store.state, .idle)
    }

    func testDoneDismissClosesAndResets() async {
        let store = await loadedStore()
        var isPresented = true
        let presented = Binding(get: { isPresented }, set: { isPresented = $0 })
        CatchUpSheet.dismissViaDone(presented: presented, store: store)
        XCTAssertFalse(isPresented)
        XCTAssertEqual(store.state, .idle)
    }

    func testEscapeDismissClosesAndResets() async {
        let store = await failedStore()
        var isPresented = true
        let presented = Binding(get: { isPresented }, set: { isPresented = $0 })
        CatchUpSheet.dismissViaEscape(presented: presented, store: store)
        XCTAssertFalse(isPresented)
        XCTAssertEqual(store.state, .idle)
    }

    func testClickOutsideDismissClosesAndResets() async {
        let store = await loadedStore()
        // System dismiss: the popover already flipped the binding to
        // false before the onChange net runs the router.
        var isPresented = false
        let presented = Binding(get: { isPresented }, set: { isPresented = $0 })
        CatchUpSheet.dismissViaClickOutside(presented: presented, store: store)
        XCTAssertFalse(isPresented)
        XCTAssertEqual(store.state, .idle)
    }

    func testReopenAfterDismissStartsIdle() async {
        let store = await loadedStore()
        var isPresented = true
        let presented = Binding(get: { isPresented }, set: { isPresented = $0 })
        CatchUpSheet.dismissViaDone(presented: presented, store: store)
        XCTAssertFalse(isPresented)
        CatchUpSheet.open(presented: presented, store: store)
        XCTAssertTrue(isPresented)
        XCTAssertEqual(store.state, .idle)
    }

    func testDismissWhenAlreadyClosedIsHarmless() {
        let store = CatchUpStore(defaults: defaults, keyStore: CatchUpMemoryKeyStore())
        XCTAssertEqual(store.state, .idle)
        var isPresented = false
        let presented = Binding(get: { isPresented }, set: { isPresented = $0 })
        // The onChange net + explicit intents overlap (e.g. Esc fires both
        // .onExitCommand and the system dismiss); repeats must no-op.
        CatchUpSheet.dismissViaDone(presented: presented, store: store)
        CatchUpSheet.dismissViaEscape(presented: presented, store: store)
        CatchUpSheet.dismissViaClickOutside(presented: presented, store: store)
        XCTAssertFalse(isPresented)
        XCTAssertEqual(store.state, .idle)
    }
}
