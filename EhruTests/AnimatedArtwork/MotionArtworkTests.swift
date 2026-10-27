import XCTest
@testable import Ehru

final class MotionArtworkTests: XCTestCase {
    private let base = URL(string: "https://video-ssl.itunes.apple.com/album/master.m3u8")!

    func testSelectsPhoneSizedSDRVariantAndResolvesRelativePaths() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=2160x2160,CODECS="hvc1",VIDEO-RANGE=SDR
        big.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=720x720,CODECS="avc1",VIDEO-RANGE=SDR
        medium.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=360x360,CODECS="avc1",VIDEO-RANGE=SDR
        small.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=720x720,CODECS="dvh1",VIDEO-RANGE=PQ
        hdr.m3u8
        """
        let variants = try MotionPlaylist.variants(master, base: base)
        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(MotionPlaylist.displayVariant(variants)?.url.absoluteString, "https://video-ssl.itunes.apple.com/album/medium.m3u8")
        XCTAssertEqual(MotionPlaylist.attributes(#"CODECS="avc1,mp4a",BANDWIDTH=123"#)["CODECS"], "avc1,mp4a")
    }

    func testParsesInitAndByteRangesForOfflineMP4Assembly() throws {
        let media = """
        #EXTM3U
        #EXT-X-MAP:URI="clip.mp4",BYTERANGE="100@0"
        #EXTINF:3,
        #EXT-X-BYTERANGE:200@100
        clip.mp4
        #EXTINF:3,
        #EXT-X-BYTERANGE:300
        clip.mp4
        #EXT-X-ENDLIST
        """
        let parts = try MotionPlaylist.parts(media, base: base)
        XCTAssertEqual(parts.map(\.offset), [0, 100, 300])
        XCTAssertEqual(parts.map(\.length), [100, 200, 300])
        XCTAssertTrue(parts.allSatisfy { $0.url.lastPathComponent == "clip.mp4" })
    }

    func testRefusesEncryptionLiveStreamsInvalidRangesAndUntrustedHosts() throws {
        let end = "\n#EXT-X-ENDLIST"
        for media in [
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128\n#EXT-X-MAP:URI=\"init.mp4\"\n1.m4s" + end,
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n1.m4s",
            "#EXTM3U\n1.ts" + end,
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-BYTERANGE:-1@0\n1.m4s" + end,
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-BYTERANGE:10\nother.mp4" + end,
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\nhttps://example.com/1.m4s" + end
        ] { XCTAssertThrowsError(try MotionPlaylist.parts(media, base: base), media) }
        XCTAssertThrowsError(try MotionPlaylist.trustedURL("http://video.apple.com/clip.mp4"))
        XCTAssertThrowsError(try MotionPlaylist.trustedURL("https://apple.com.example.com/clip.mp4"))
    }

    func testAlbumMatchingRejectsOtherArtistsAndSequels() {
        let found = [
            AppleMotionService.AlbumResult(collectionId: 1, collectionName: "IGOR", artistName: "Tyler, The Creator", collectionExplicitness: "explicit"),
            AppleMotionService.AlbumResult(collectionId: 2, collectionName: "IGOR II", artistName: "Tyler, The Creator", collectionExplicitness: nil),
            AppleMotionService.AlbumResult(collectionId: 3, collectionName: "IGOR", artistName: "Someone Else", collectionExplicitness: nil)
        ]
        XCTAssertEqual(AppleMotionService.candidates(found, album: "IGOR", artist: "Tyler, The Creator").map(\.collectionId), [1])
    }

    private struct FakeApple: HTTPClient {
        func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
            let body: String
            switch url.host {
            case "itunes.apple.com":
                body = #"{"results":[{"collectionId":1,"collectionName":"IGOR","artistName":"Tyler, The Creator","collectionExplicitness":"explicit"}]}"#
            case "music.apple.com":
                body = url.path.hasSuffix(".js") ? "eyJfixture.cGF5bG9hZA.signature" : #"<script src="/assets/index-fixture.js"></script>"#
            case "amp-api.music.apple.com":
                XCTAssertEqual(headers["Origin"], "https://music.apple.com")
                XCTAssertEqual(headers["Authorization"], "Bearer eyJfixture.cGF5bG9hZA.signature")
                body = #"{"data":[{"attributes":{"editorialVideo":{"motionDetailSquare":{"video":"https://video-ssl.itunes.apple.com/cover/master.m3u8"}}}}]}"#
            default: throw URLError(.badURL)
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testSearchResolvesCatalogMotionWithSessionOnlyWebAuthentication() async throws {
        let service = AppleMotionService(client: FakeApple())
        let match = try await service.find(album: "IGOR", artist: "Tyler, The Creator", country: "us")
        XCTAssertEqual(match?.catalogId, 1)
        XCTAssertEqual(match?.master.host, "video-ssl.itunes.apple.com")
    }
}
