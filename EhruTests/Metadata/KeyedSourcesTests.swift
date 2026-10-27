@testable import Ehru
import XCTest

final class KeyedSourcesTests: XCTestCase {
    private struct FakeHTTP: HTTPClient {
        let status: Int
        let body: String

        func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testLastFmMapping() async throws {
        let body = """
        {"results":{"trackmatches":{"track":[
          {"name":"Yellow","artist":"Coldplay","image":[{"#text":"https://lastfm/300x300/abc.png","size":"extralarge"}]},
          {"name":"Yellow (Live)","artist":"Coldplay","image":[{"#text":"https://lastfm/2a96cbd8b46e442fc41c2b86b821562f.png","size":"large"}]}
        ]}}}
        """
        let provider = LastFmProvider(client: FakeHTTP(status: 200, body: body), apiKey: { "key" })
        let found = try await provider.searchTrack(title: "Yellow", artist: "Coldplay", album: nil)
        XCTAssertEqual(found.map(\.title), ["Yellow", "Yellow (Live)"])
        XCTAssertEqual(found[0].coverArtUrl, "https://lastfm/300x300/abc.png")
        XCTAssertNil(found[1].coverArtUrl) // Last.fm's placeholder star
        XCTAssertEqual(found[0].sourceName, "Last.fm")
    }

    func testLastFmKeyErrorsAreCredentialFailures() async {
        let bad = LastFmProvider(client: FakeHTTP(status: 403, body: #"{"error":10,"message":"Invalid API key"}"#), apiKey: { "wrong" })
        do {
            _ = try await bad.searchTrack(title: "Yellow", artist: nil, album: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(classifyProviderFailure(error).status, .authFailed)
        }
        XCTAssertEqual(LastFmProvider.apiError(29, nil).status, .rateLimited)
        let missing = LastFmProvider(client: FakeHTTP(status: 200, body: "{}"), apiKey: { nil })
        let outcome = await MetadataService.searchOne(missing, selection: MetadataSources.all, availability: .notConfigured(LastFmProvider.notConfigured),
                                                      title: "Yellow", artist: nil, album: nil, durationMs: nil, retry: RetryPolicy())
        XCTAssertEqual(outcome.1.status, .notConfigured)
    }

    func testFanartUrlsAreRankedByLikes() {
        let list: [[String: Any]] = [["url": "http://a/1.jpg", "likes": "2"], ["url": "https://a/2.jpg", "likes": "9"], ["url": "https://a/3.jpg"]]
        XCTAssertEqual(ArtworkSearch.fanartUrls(list), ["https://a/2.jpg", "https://a/1.jpg", "https://a/3.jpg"])
        XCTAssertEqual(ArtworkSearch.fanartUrls(nil), [])
    }

    func testDiscogsHelpers() {
        XCTAssertEqual(ArtworkSearch.discogsArtistId("https://www.discogs.com/artist/151223-Drake"), 151_223)
        XCTAssertNil(ArtworkSearch.discogsArtistId("https://www.discogs.com/label/1"))
        let results: [[String: Any]] = [["cover_image": "https://i.discogs.com/a.jpg"], ["cover_image": "https://s.discogs.com/spacer.gif", "thumb": "x"], ["thumb": "https://i.discogs.com/t.jpg"]]
        XCTAssertEqual(ArtworkSearch.discogsImages(results, keys: ["cover_image", "thumb"]), ["https://i.discogs.com/a.jpg", "https://i.discogs.com/t.jpg"])
        XCTAssertEqual(ArtworkSearch.discogsHeaders("t0k")["Authorization"], "Discogs token=t0k")
    }

    func testSourcesWithoutKeysAreSkipped() async {
        let search = ArtworkSearch(client: FakeHTTP(status: 500, body: ""), key: { _ in nil })
        let covers = await search.albumCovers(album: "IGOR", artist: "Tyler, The Creator")
        XCTAssertTrue(covers.isEmpty) // every source failed or was skipped, nothing made up
    }
}
