import SwiftUI

/// Embedded cover art of an audio file, loaded off the main thread, with a quiet placeholder.
struct SongArtworkView: View {
    let url: URL?
    var maxPixels = 300
    var placeholder = "music.note"
    @Environment(\.palette) private var palette
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(palette.surfaceVariant)
                Image(systemName: placeholder)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = ArtworkLoader.shared.cachedImage(for: url, maxPixels: maxPixels)
            if image == nil { image = await ArtworkLoader.shared.image(for: url, maxPixels: maxPixels) }
        }
    }
}

extension SongArtworkView {
    init(song: Song?, maxPixels: Int = 300) {
        self.init(url: song?.url, maxPixels: maxPixels)
    }
}

/// An album's cover: its first song's embedded art.
struct AlbumArtworkView: View {
    let albumId: Int64
    var maxPixels = 400
    @Environment(LibraryStore.self) private var library

    var body: some View {
        SongArtworkView(url: library.albumCoverSong[albumId]?.url, maxPixels: maxPixels, placeholder: "square.stack")
    }
}

/// A picture file (custom playlist cover, artist photo) or a fallback.
struct FileImageView<Fallback: View>: View {
    let path: String?
    var maxPixels = 400
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { fallback() }
        }
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            image = await ArtworkLoader.shared.image(atPath: LibraryPaths.resolveImage(path), maxPixels: maxPixels)
        }
    }
}

/// A playlist's cover: the user's own artwork, or the default playlist cover.
struct PlaylistCoverView: View {
    let playlist: Playlist
    @Environment(\.palette) private var palette

    var body: some View {
        FileImageView(path: playlist.artworkPath) {
            ZStack {
                Rectangle().fill(palette.surfaceVariant)
                Image(systemName: "music.note.list").font(.system(size: 28)).foregroundStyle(palette.onSurfaceVariant)
            }
        }
    }
}

/// An artist's picture, or their monogram.
struct ArtistArtworkView: View {
    let artist: Artist
    var fontSize: CGFloat = 36

    var body: some View {
        FileImageView(path: artist.artworkPath) { ArtistMonogram(name: artist.name, fontSize: fontSize) }
    }
}

/// The first letter of a name on a tone picked from the name, so each artist keeps theirs.
struct ArtistMonogram: View {
    let name: String
    var fontSize: CGFloat = 18
    @Environment(\.palette) private var palette

    var body: some View {
        let letter = name.trimmed.first.map { String($0).uppercased() } ?? "?"
        ZStack {
            Rectangle().fill(palette.surfaceVariant)
            Text(letter).font(.system(size: fontSize, weight: .bold)).foregroundStyle(palette.onSurface)
        }
    }
}
