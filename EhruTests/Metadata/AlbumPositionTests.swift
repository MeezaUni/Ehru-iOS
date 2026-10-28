import XCTest
@testable import Ehru

final class AlbumPositionTests: XCTestCase {
    private actor FixtureHTTP: HTTPClient {
        let body: String
        private(set) var requests = 0
        init(_ body: String) { self.body = body }
        func request(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
            requests += 1
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func plan(local: LocalTrackTags, match: MetadataCandidate, fillOnly: Bool = true) -> FieldFixPlan {
        FieldFixPlanner.plan(fields: [.trackNumber, .discNumber], fillOnly: fillOnly, local: local, match: match,
                             genre: nil, artwork: nil, releaseDate: nil, bpm: nil)
    }

    func testOrderingFillsMissingTagsButPreservesValidLocalNumbers() {
        var match = MetadataCandidate(id: "itunes_1", title: "Song", artist: "Artist", album: "Album", trackNumber: 7)
        match.discNumber = 2
        var local = LocalTrackTags(title: "Song", artist: "Artist", album: "Album")
        let filled = plan(local: local, match: match)
        XCTAssertEqual(filled.request?.trackNumber, 7)
        XCTAssertEqual(filled.request?.discNumber, 2)
        local.trackNumber = 3
        local.discNumber = 1
        XCTAssertNil(plan(local: local, match: match).request)
        XCTAssertEqual(plan(local: local, match: match, fillOnly: false).request?.discNumber, 2)
    }

    func testOrderingDoesNotBorrowNumbersFromAnotherEditionOrDisc() {
        var match = MetadataCandidate(id: "itunes_1", title: "Song", artist: "Artist", album: "Album (Deluxe)", trackNumber: 7)
        match.discNumber = 1
        var local = LocalTrackTags(title: "Song", artist: "Artist", album: "Album")
        XCTAssertNil(plan(local: local, match: match).request)
        match.album = "Album"
        local.discNumber = 2
        XCTAssertNil(plan(local: local, match: match).request)
        match.trackNumber = 0
        match.discNumber = 0
        XCTAssertNil(plan(local: local, match: match, fillOnly: false).request)
    }

    func testMusicBrainzUsesTrackAndMediumPositionsAndRejectsRepeatedRecordings() throws {
        let json = #"{"id":"release","title":"Album","media":[{"position":2,"tracks":[{"position":4,"recording":{"id":"recording"}}]}]}"#
        let list = try JSONDecoder().decode(ReleaseTracklist.self, from: Data(json.utf8))
        XCTAssertEqual(list.position(recordingID: "recording"), AlbumTrackPosition(disc: 2, track: 4))
        XCTAssertNil(list.position(recordingID: "absent"))
        let duplicates = json.replacingOccurrences(of: #"{"position":4,"recording":{"id":"recording"}}"#,
                                                   with: #"{"position":4,"recording":{"id":"recording"}},{"position":5,"recording":{"id":"recording"}}"#)
        XCTAssertNil(try JSONDecoder().decode(ReleaseTracklist.self, from: Data(duplicates.utf8)).position(recordingID: "recording"))
    }

    func testITunesReadsRealTrackAndDiscNumbers() throws {
        let json = #"{"results":[{"trackId":12,"collectionId":9,"trackName":"Song","artistName":"Artist","collectionName":"Album","trackNumber":8,"discNumber":2}]}"#
        let response = try JSONDecoder().decode(ITunesProvider.Response.self, from: Data(json.utf8))
        let match = try XCTUnwrap(ITunesProvider.candidates(response).first)
        XCTAssertEqual(match.trackNumber, 8)
        XCTAssertEqual(match.discNumber, 2)
        XCTAssertEqual(match.releaseId, "9")
    }

    func testMusicBrainzLooksUpTheChosenReleaseAndCachesItsTracklist() async throws {
        let recording = "3ca61e12-f1c6-4c88-9c10-d2b4ab504c5e"
        let release = "b30d7940-2a3c-4b37-9a45-2456816fb558"
        let http = FixtureHTTP("""
        {"id":"\(release)","title":"Album","media":[{"position":2,"tracks":[{"position":6,"recording":{"id":"\(recording)"}}]}]}
        """)
        let provider = MusicBrainzProvider(client: http)
        var match = MetadataCandidate(id: "mb_" + recording, title: "Song", artist: "Artist", album: "Album")
        match.releaseId = release
        let first = try await provider.albumPosition(match)
        let second = try await provider.albumPosition(match)
        XCTAssertEqual(first, AlbumTrackPosition(disc: 2, track: 6))
        XCTAssertEqual(second, first)
        let requests = await http.requests
        XCTAssertEqual(requests, 1)
    }

    func testDeezerDetailMustBelongToTheSelectedAlbum() async {
        let http = FixtureHTTP(#"{"id":12,"title":"Song","track_position":7,"disk_number":2,"album":{"id":9,"title":"Album"}}"#)
        let service = MetadataService(client: http)
        var match = MetadataCandidate(id: "deezer_12", title: "Song", artist: "Artist", album: "Album", sourceName: "Deezer")
        match.deezerAlbumId = 9
        let (found, _) = await service.withAlbumPosition(match)
        XCTAssertEqual(found.trackNumber, 7)
        XCTAssertEqual(found.discNumber, 2)
        match.deezerAlbumId = 10
        let (mismatch, _) = await service.withAlbumPosition(match)
        XCTAssertEqual(mismatch.trackNumber, 0)
        XCTAssertEqual(mismatch.discNumber, 0)
    }

    func testOldAllFieldsSettingsGainOrderingWithoutResettingPreferences() throws {
        let json = #"{"fields":["TITLE","ARTIST","ALBUM","YEAR","GENRE"],"source":"iTunes","acceptAt":0.91}"#
        let settings = try JSONDecoder().decode(FixTagsStore.Settings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.fields.contains("TRACK_NUMBER"))
        XCTAssertTrue(settings.fields.contains("DISC_NUMBER"))
        XCTAssertEqual(settings.source, "iTunes")
        XCTAssertEqual(settings.acceptAt, 0.91)
        let custom = json.replacingOccurrences(of: #"["TITLE","ARTIST","ALBUM","YEAR","GENRE"]"#, with: #"["GENRE"]"#)
        XCTAssertEqual(try JSONDecoder().decode(FixTagsStore.Settings.self, from: Data(custom.utf8)).fields, ["GENRE"])
        let saved = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(FixTagsStore.Settings.self, from: saved), settings)
    }
}
