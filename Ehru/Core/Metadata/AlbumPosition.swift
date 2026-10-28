import Foundation

/// Keep edition words (Deluxe, live, remaster…) when validating a tracklist position.
func albumPositionTitle(_ title: String) -> String {
    title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

struct AlbumTrackPosition: Equatable, Sendable {
    let disc: Int
    let track: Int
    var isValid: Bool { (1...65535).contains(disc) && (1...65535).contains(track) }
}

/// A MusicBrainz release's actual media/track positions; repeated recordings are ambiguous.
struct ReleaseTracklist: Decodable, Sendable {
    struct Medium: Decodable, Sendable {
        struct Track: Decodable, Sendable {
            struct Recording: Decodable, Sendable { let id: String }
            let position: Int
            let recording: Recording?
        }
        let position: Int
        let tracks: [Track]?
    }
    let id: String
    let title: String
    let media: [Medium]?

    func position(recordingID: String) -> AlbumTrackPosition? {
        let matches = (media ?? []).flatMap { medium in
            (medium.tracks ?? []).filter { $0.recording?.id == recordingID }.map {
                AlbumTrackPosition(disc: medium.position, track: $0.position)
            }
        }
        guard matches.count == 1, matches[0].isValid else { return nil }
        return matches[0]
    }
}
