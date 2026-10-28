import XCTest
@testable import Ehru

final class AlbumPositionTests: XCTestCase {
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
