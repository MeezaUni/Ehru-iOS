import Foundation

/// One scanned file's tags exactly as read: nothing here is parsed or resolved.
struct RawTrack: Equatable {
    var songId: Int64
    var title: String
    var rawArtist: String
    var rawAlbumArtist: String?
    var album: String
    var trackNumber: Int
    var discNumber: Int
    var folder: String
    var isCompilation: Bool

    /// The only view of a track that album grouping may see: it has no track-artist field.
    func toAlbumInput() -> AlbumInput {
        AlbumInput(
            songId: songId, album: album, rawAlbumArtist: rawAlbumArtist, folder: folder,
            trackNumber: trackNumber, discNumber: discNumber, isCompilation: isCompilation
        )
    }
}

struct AlbumInput: Equatable {
    let songId: Int64
    let album: String
    let rawAlbumArtist: String?
    let folder: String
    let trackNumber: Int
    let discNumber: Int
    let isCompilation: Bool
}

enum CreditRole: String, Codable, Hashable {
    case primary = "PRIMARY"
    case featured = "FEATURED"
}
