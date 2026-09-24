// PresenceTests.swift — om-presence lane: envelopes, status table,
// store fetch/set/cache with mock fetchers (no core, no network).
import DietDesign
import XCTest

@testable import OstMacCore

@MainActor
final class PresenceTests: XCTestCase {
    func testOwnEnvelopeDecodes() throws {
        let data = """
        {"ok":true,"availability":"Busy","activity":"InACall"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(PresenceResponse.self, from: data)
        XCTAssertEqual(p.availability, "Busy")
        XCTAssertEqual(p.activity, "InACall")
    }

    func testUserEnvelopeDecodes() throws {
        let data = """
        {"ok":true,"id":"gid-7","availability":"Away","activity":"Away"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(UserPresenceResponse.self, from: data)
        XCTAssertEqual(p.id, "gid-7")
        XCTAssertEqual(p.availability, "Away")
    }

    func testStatusTableRoundtrip() {
        // ost CLI --set values → server availability → picker row.
        let pairs: [(PresenceStatus, String)] = [
            (.available, "Available"), (.busy, "Busy"), (.dnd, "DoNotDisturb"),
            (.away, "Away"), (.offline, "Offline"),
        ]
        for (status, avail) in pairs {
            XCTAssertEqual(status.availability, avail)
            XCTAssertEqual(PresenceStatus.from(availability: avail), status)
        }
        XCTAssertEqual(PresenceStatus.dnd.rawValue, "dnd")
        XCTAssertNil(PresenceStatus.from(availability: "PresenceUnknown"))
        XCTAssertNil(PresenceStatus.from(availability: "FutureValue"))
    }

    func testOnlineRuleMatchesOstTui() {
        // ost TUI: online = availability ∉ {Offline, PresenceUnknown}.
        for avail in ["Available", "Busy", "DoNotDisturb", "Away", "BeRightBack", "Whatever"] {
            XCTAssertTrue(PresenceFormat.isOnline(availability: avail), avail)
        }
        XCTAssertFalse(PresenceFormat.isOnline(availability: "Offline"))
        XCTAssertFalse(PresenceFormat.isOnline(availability: "PresenceUnknown"))
    }

    func testLabelCollapsesEqualPair() {
        XCTAssertEqual(
            PresenceFormat.label(availability: "Available", activity: "Available"), "Available")
        XCTAssertEqual(
            PresenceFormat.label(availability: "Busy", activity: "InACall"), "Busy · InACall")
        XCTAssertEqual(PresenceFormat.label(availability: "Away", activity: ""), "Away")
    }

    func testTeamsAvailabilityMapsToDietPresence() {
        // DND rides the purple token (DietPresence.dnd), never busy-red.
        XCTAssertEqual(DietPresence(teamsAvailability: "DoNotDisturb"), .dnd)
        XCTAssertEqual(DietPresence(teamsAvailability: "Available"), .available)
        XCTAssertEqual(DietPresence(teamsAvailability: "Busy"), .busy)
        XCTAssertEqual(DietPresence(teamsAvailability: "Away"), .away)
        XCTAssertEqual(DietPresence(teamsAvailability: "BeRightBack"), .away)
        XCTAssertEqual(DietPresence(teamsAvailability: "Offline"), .offline)
        XCTAssertNil(DietPresence(teamsAvailability: nil))
        XCTAssertNil(DietPresence(teamsAvailability: "PresenceUnknown"))
        XCTAssertNil(DietPresence(teamsAvailability: "FutureValue"))
    }

    func testRefreshOwnAdoptsAndClearsError() async {
        let store = PresenceStore(
            ownFetcher: { PresenceResponse(ok: true, availability: "Away", activity: "Away") })
        await store.refreshOwn()
        XCTAssertEqual(store.own?.availability, "Away")
        XCTAssertNil(store.error)
    }

    func testRefreshOwnFailureKeepsStale() async {
        struct Boom: Error {}
        let store = PresenceStore(
            ownFetcher: { throw Boom() })
        store.adoptOwn(PresenceResponse(ok: true, availability: "Available", activity: "Available"))
        await store.refreshOwn()
        XCTAssertEqual(store.own?.availability, "Available") // stale kept
        XCTAssertNotNil(store.error)
    }

    func testSetAppliesEcho() async {
        let store = PresenceStore(
            setFetcher: { want in
                XCTAssertEqual(want, "busy")
                return PresenceResponse(ok: true, availability: "Busy", activity: "InACall")
            })
        store.set(status: .busy)
        // set() is fire-and-forget; poll briefly for the echo.
        for _ in 0 ..< 50 {
            if store.own?.availability == "Busy" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.own?.availability, "Busy")
        XCTAssertFalse(store.setting)
    }

    func testRefreshPeersCachesByID() async {
        let store = PresenceStore(
            userFetcher: { id in
                UserPresenceResponse(ok: true, id: id, availability: "Available", activity: "Available")
            })
        await store.refreshPeers(ids: ["u1", "u2"])
        XCTAssertEqual(store.peers.count, 2)
        XCTAssertEqual(store.peers["u1"]?.availability, "Available")
        XCTAssertNil(store.error)
    }

    func testRefreshChatPeerPinsToChat() async {
        let store = PresenceStore(
            userFetcher: { _ in
                UserPresenceResponse(ok: true, id: "gid-9", availability: "Busy", activity: "InACall")
            })
        await store.refreshChatPeer(chatID: "19:t", userID: "gid-9")
        XCTAssertEqual(store.availabilityForChat("19:t"), "Busy")
        XCTAssertEqual(store.peers["gid-9"]?.activity, "InACall")
        XCTAssertNil(store.availabilityForChat("19:other"))
    }

    func testClearDropsEverything() {
        let store = PresenceStore()
        store.adoptOwn(PresenceResponse(ok: true, availability: "Available", activity: "Available"))
        store.adoptChatPeer(
            chatID: "19:t",
            response: UserPresenceResponse(ok: true, id: "u", availability: "Busy", activity: "x"))
        store.clear()
        XCTAssertNil(store.own)
        XCTAssertTrue(store.peers.isEmpty)
        XCTAssertTrue(store.chatPeers.isEmpty)
    }

    func testDemoFixtures() {
        XCTAssertEqual(DemoData.ownPresence().availability, "Available")
        let peers = DemoData.peerPresence()
        XCTAssertEqual(peers[DemoData.avaID]?.availability, "Busy")
    }
}
