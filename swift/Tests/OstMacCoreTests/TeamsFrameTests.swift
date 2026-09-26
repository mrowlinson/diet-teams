// TeamsFrameTests.swift — teams-frame PROTOTYPE: URL allowlist,
// launch-flag parsing, and keep-alive/destroy seams. No live login,
// no network — pure config + store lifecycle only.
import XCTest

@testable import OstMacCore

@MainActor
final class TeamsFrameTests: XCTestCase {
    // MARK: - Allowlist

    func testAllowsTeamsHosts() {
        for raw in [
            "https://teams.microsoft.com/",
            "https://teams.microsoft.com/l/entity/abc",
            "https://sub.teams.microsoft.com/x",
            "https://teams.live.com/meet/123",
        ] {
            XCTAssertTrue(
                TeamsFrameConfig.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testAllowsAuthAndContentHosts() {
        for raw in [
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://login.live.com/oauth20_authorize.srf",
            "https://contoso.sharepoint.com/sites/x",
            "https://contoso-my.sharepoint.com/personal/y",
            "https://outlook.office.com/owa/",
            "https://res.cdn.office.net/assets/x.js",
        ] {
            XCTAssertTrue(
                TeamsFrameConfig.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testBlocksNonAllowlistedAndSpoofs() {
        for raw in [
            "https://evil.com/teams.microsoft.com",
            "https://teams.microsoft.com.evil.com/",
            "https://notteams-microsoft.com/",
            "https://example.com/",
        ] {
            XCTAssertFalse(
                TeamsFrameConfig.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testAboutBlankAllowedOtherHostlessBlocked() {
        XCTAssertTrue(TeamsFrameConfig.isAllowed(URL(string: "about:blank")!))
        XCTAssertFalse(TeamsFrameConfig.isAllowed(URL(string: "file:///etc/passwd")!))
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertTrue(
            TeamsFrameConfig.isAllowed(URL(string: "https://Teams.Microsoft.Com/x")!))
    }

    // MARK: - Launch flags

    func testLaunchURLDefault() {
        XCTAssertEqual(
            TeamsFrameConfig.launchURL(args: ["Better Teams"]),
            "https://teams.microsoft.com")
    }

    func testLaunchURLFromFlag() {
        let deep = "https://teams.microsoft.com/l/entity/abc123?label=App"
        XCTAssertEqual(
            TeamsFrameConfig.launchURL(args: ["Better Teams", "--teams-frame-url", deep]),
            deep)
    }

    func testLaunchURLMissingValueFallsBackToDefault() {
        XCTAssertEqual(
            TeamsFrameConfig.launchURL(args: ["Better Teams", "--teams-frame-url"]),
            "https://teams.microsoft.com")
    }

    func testShouldOpen() {
        XCTAssertFalse(TeamsFrameConfig.shouldOpen(args: ["Better Teams"]))
        XCTAssertTrue(TeamsFrameConfig.shouldOpen(args: ["Better Teams", "--show-teams-frame"]))
        XCTAssertTrue(TeamsFrameConfig.shouldOpen(args: [
            "Better Teams", "--teams-frame-url", "https://teams.microsoft.com",
        ]))
    }

    func testFullFrameFlag() {
        XCTAssertFalse(TeamsFrameConfig.fullFrame(args: ["Better Teams"]))
        XCTAssertTrue(TeamsFrameConfig.fullFrame(args: ["Better Teams", "--teams-frame-full"]))
    }

    // MARK: - Keep-alive / destroy seams

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dev.ostmac.teams-frame-tests")!
    }

    override func tearDown() {
        freshDefaults().removeObject(forKey: TeamsFrameConfig.keepAliveMinutesKey)
        super.tearDown()
    }

    func testKeepAliveDefaultIs15() {
        let defaults = freshDefaults()
        defaults.removeObject(forKey: TeamsFrameConfig.keepAliveMinutesKey)
        XCTAssertEqual(TeamsFrameConfig.keepAliveMinutes(defaults: defaults), 15)
    }

    func testKeepAliveZeroMeansInstant() {
        let defaults = freshDefaults()
        defaults.set(0, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        XCTAssertEqual(TeamsFrameConfig.keepAliveMinutes(defaults: defaults), 0)
        let store = TeamsFrameStore(defaults: defaults)
        store.activate()
        XCTAssertTrue(store.alive)
        XCTAssertNotNil(store.pool)
        store.deactivate()
        XCTAssertFalse(store.alive)
        XCTAssertNil(store.pool)
        XCTAssertNil(store.dataStore)
        XCTAssertFalse(store.keepAliveArmed)
    }

    func testDeactivateArmsTimerWhenPositive() {
        let defaults = freshDefaults()
        defaults.set(15, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        let store = TeamsFrameStore(defaults: defaults)
        store.activate()
        store.deactivate()
        XCTAssertTrue(store.alive)
        XCTAssertTrue(store.keepAliveArmed)
        XCTAssertNotNil(store.pool)
        store.destroy() // cleanup: disarm the timer
    }

    func testActivateCancelsArmedTimer() {
        let defaults = freshDefaults()
        defaults.set(15, forKey: TeamsFrameConfig.keepAliveMinutesKey)
        let store = TeamsFrameStore(defaults: defaults)
        store.activate()
        store.deactivate()
        XCTAssertTrue(store.keepAliveArmed)
        store.activate()
        XCTAssertFalse(store.keepAliveArmed)
        XCTAssertTrue(store.alive)
        store.destroy()
    }

    func testDestroyOrphansPoolAndStore() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        store.activate()
        XCTAssertNotNil(store.pool)
        XCTAssertNotNil(store.dataStore)
        store.destroy()
        XCTAssertNil(store.pool)
        XCTAssertNil(store.dataStore)
        XCTAssertFalse(store.alive)
    }

    func testReactivateAfterDestroyRebuilds() {
        let store = TeamsFrameStore(defaults: freshDefaults())
        store.activate()
        store.destroy()
        XCTAssertFalse(store.alive)
        store.activate()
        XCTAssertTrue(store.alive)
        XCTAssertNotNil(store.pool)
        XCTAssertNotNil(store.dataStore)
        store.destroy()
    }

    func testUserAgentSuffixCarriesSafariTokens() {
        // Regression: stock WKWebView UA lands on /v2/unsupported-browser.
        XCTAssertTrue(TeamsFrameConfig.userAgentSuffix.contains("Safari/"))
        XCTAssertTrue(TeamsFrameConfig.userAgentSuffix.contains("Version/"))
    }

    func testCropV0HasPositiveInsets() {
        XCTAssertGreaterThan(TeamsFrameCrop.v0.left, 0)
        XCTAssertGreaterThan(TeamsFrameCrop.v0.top, 0)
        XCTAssertEqual(TeamsFrameCrop.none, TeamsFrameCrop(left: 0, top: 0))
    }
}
