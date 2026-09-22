// TenorTests.swift — om-cmdk lane: URL builders, payload decode, off-state.
import XCTest

@testable import OstMacCore

final class TenorTests: XCTestCase {
    // MARK: - URL builders

    func testSearchURLShape() {
        let url = TenorClient.searchURL(query: "party parrot", apiKey: "K")!
        XCTAssertEqual(url.host, "tenor.googleapis.com")
        XCTAssertTrue(url.path.hasSuffix("/v2/search"))
        XCTAssertTrue(url.absoluteString.contains("key=K"))
        XCTAssertTrue(url.absoluteString.contains("media_filter=gif,tinygif"))
        XCTAssertTrue(url.absoluteString.contains("contentfilter=medium"))
        // Query is percent-encoded, never raw.
        XCTAssertTrue(url.absoluteString.contains("q=party%20parrot"))
    }

    func testFeaturedURLShape() {
        let url = TenorClient.featuredURL(apiKey: "K", limit: 10)!
        XCTAssertTrue(url.path.hasSuffix("/v2/featured"))
        XCTAssertTrue(url.absoluteString.contains("limit=10"))
    }

    func testEmptyKeyYieldsNil() {
        XCTAssertNil(TenorClient.searchURL(query: "x", apiKey: "  "))
        XCTAssertNil(TenorClient.featuredURL(apiKey: ""))
    }

    func testLimitClamped() {
        XCTAssertTrue(TenorClient.featuredURL(apiKey: "K", limit: 999)!.absoluteString.contains("limit=50"))
        XCTAssertTrue(TenorClient.featuredURL(apiKey: "K", limit: 0)!.absoluteString.contains("limit=1"))
    }

    // MARK: - decode

    func testDecodeSearchPayload() throws {
        let gifs = try TenorClient.decode(Data(Self.payload.utf8))
        XCTAssertEqual(gifs.count, 2)
        XCTAssertEqual(gifs[0].id, "111")
        XCTAssertEqual(gifs[0].title, "Party Parrot")
        XCTAssertEqual(gifs[0].previewURL, "https://t/tiny1")
        XCTAssertEqual(gifs[0].fullURL, "https://t/full1")
        // No tinygif → preview falls back to the full gif.
        XCTAssertEqual(gifs[1].previewURL, "https://t/full2")
        XCTAssertEqual(gifs[1].fullURL, "https://t/full2")
    }

    func testDecodeSkipsUnplayable() throws {
        let json = #"{"results":[{"id":"9","title":"x","media_formats":{"mp4":{"url":"https://t/v"}}}]}"#
        XCTAssertEqual(try TenorClient.decode(Data(json.utf8)).count, 0)
    }

    func testDecodeEmpty() throws {
        XCTAssertEqual(try TenorClient.decode(Data(#"{"results":[]}"#.utf8)).count, 0)
    }

    // MARK: - search (mocked fetcher, no network)

    func testSearchUsesFetcherAndDecodes() async throws {
        let gifs = try await TenorClient.search(query: "parrot", apiKey: "K") { url in
            XCTAssertTrue(url.absoluteString.contains("q=parrot"))
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.payload.utf8), resp)
        }
        XCTAssertEqual(gifs.count, 2)
    }

    func testSearchWithoutKeyNeverFetches() async {
        var fetched = false
        do {
            _ = try await TenorClient.search(query: "parrot", apiKey: "") { _ in
                fetched = true
                throw TenorError.network("unreachable")
            }
            XCTFail("expected missingKey")
        } catch TenorError.missingKey {
            // Expected: no request without a key.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(fetched)
    }

    func testHTTPErrorSurfaces() async {
        do {
            _ = try await TenorClient.featured(apiKey: "BAD") { url in
                let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            XCTFail("expected badResponse")
        } catch TenorError.badResponse(let m) {
            XCTAssertTrue(m.contains("403"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - composer insert

    func testAppendGIFJoinsWithSpace() {
        XCTAssertEqual(ConversationView.appendGIF("https://t/g", to: ""), "https://t/g")
        XCTAssertEqual(ConversationView.appendGIF("https://t/g", to: "look"), "look https://t/g")
    }

    private nonisolated static let payload = """
        {"results":[
          {"id":"111","title":"Party Parrot","media_formats":{
            "tinygif":{"url":"https://t/tiny1"},
            "gif":{"url":"https://t/full1"}}},
          {"id":"222","title":"","media_formats":{
            "gif":{"url":"https://t/full2"}}}
        ]}
        """
}
