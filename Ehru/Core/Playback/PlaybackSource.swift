import Foundation

/// Navigation context is separate from transition origins: a smart mix or artist can be a
/// playback source without becoming an album/playlist transition collection.
enum PlaybackSource: Hashable, Codable, Sendable {
    case album(Int64), playlist(Int64), artist(Int64), smartPlaylist(String)
    case library, favorites, vybe

    init(_ collection: CollectionRef) {
        self = collection.kind == .album ? .album(collection.id) : .playlist(collection.id)
    }
}
