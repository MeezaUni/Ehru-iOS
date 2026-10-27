import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: ArtworkSize.gridMin), spacing: Spacing.lg, alignment: .top)]

/// Albums as an artwork grid.
struct AlbumsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            if library.albums.isEmpty {
                EmptyState(message: library.isScanning ? "Scanning your music…" : "No albums yet.", systemImage: "square.stack")
            } else {
                LazyVGrid(columns: gridColumns, spacing: Spacing.xl) {
                    ForEach(library.albums) { album in
                        AlbumTile(album: album) { router.open(.album(album.id)) }
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
            }
        }
        .refreshable { library.scan() }
    }
}

/// The Library landing page: Playlists, Favorites, Artists and Songs, each a short horizontal
/// preview with a "More" that opens the full shelf.
struct LibraryOverviewView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router

    private static let previewLimit = 15

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Shelf(title: LibraryShelf.playlists.label, onMore: { router.open(.shelf(.playlists)) }) {
                    NewPlaylistTile { router.showsNewPlaylist = true }.frame(width: 136)
                    ForEach(library.playlists.prefix(Self.previewLimit)) { playlist in
                        PlaylistTile(playlist: playlist) { router.open(.playlist(playlist.id)) }.frame(width: 136)
                    }
                }
                section(LibraryShelf.favorites.label, empty: library.favorites.isEmpty,
                        message: "No favorites yet. Tap the heart on any song to add it here.", more: { router.open(.shelf(.favorites)) }) {
                    ForEach(Array(library.favorites.prefix(Self.previewLimit).enumerated()), id: \.element.id) { index, song in
                        SongTile(song: song) { actions.play(library.favorites, startIndex: index) }.frame(width: 136)
                    }
                }
                section(LibraryShelf.artists.label, empty: library.artists.isEmpty,
                        message: "No artists found. Pull down to rescan.", more: { router.open(.shelf(.artists)) }) {
                    ForEach(library.artists.prefix(Self.previewLimit)) { artist in
                        ArtistTile(artist: artist) { router.open(.artist(artist.id)) }.frame(width: 136)
                    }
                }
                section("Songs", empty: library.songs.isEmpty,
                        message: library.isScanning ? "Scanning your music…" : "No songs found. Pull down to rescan.", more: { router.open(.allSongs) }) {
                    ForEach(Array(library.songs.prefix(Self.previewLimit).enumerated()), id: \.element.id) { index, song in
                        SongTile(song: song) { actions.play(library.songs, startIndex: index) }.frame(width: 136)
                    }
                }
            }
            .padding(.vertical, Spacing.sm)
        }
        .refreshable { library.scan() }
    }

    @ViewBuilder
    private func section<Cards: View>(_ title: String, empty: Bool, message: String, more: @escaping () -> Void,
                                      @ViewBuilder cards: @escaping () -> Cards) -> some View {
        if empty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: title, onMore: more)
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.gutter)
            }
        } else {
            Shelf(title: title, onMore: more, content: cards)
        }
    }
}

/// A full Library shelf, opened from the overview's "More".
struct LibraryShelfView: View {
    let shelf: LibraryShelf
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            switch shelf {
            case .playlists:
                LazyVGrid(columns: gridColumns, spacing: Spacing.xl) {
                    NewPlaylistTile { router.showsNewPlaylist = true }
                    ForEach(library.playlists) { playlist in
                        PlaylistTile(playlist: playlist) { router.open(.playlist(playlist.id)) }
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
            case .favorites:
                SongList(songs: library.favorites, emptyMessage: "No favorites yet. Tap the heart on any song to add it here.",
                         emptyIcon: "heart")
            case .artists:
                LazyVGrid(columns: gridColumns, spacing: Spacing.xl) {
                    ForEach(library.artists) { artist in
                        ArtistTile(artist: artist) { router.open(.artist(artist.id)) }
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
            }
        }
        .navigationTitle(shelf.label)
    }
}

/// Every track (the Library overview's Songs "More").
struct AllSongsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        ScrollView { SongList(songs: library.songs, emptyMessage: "No songs found.", emptyIcon: "music.note") }
            .navigationTitle("Songs")
            .refreshable { library.scan() }
    }
}

/// A plain list of tracks that plays from the tapped one.
struct SongList: View {
    let songs: [Song]
    var emptyMessage = ""
    var emptyIcon = "music.note"
    var origin: CollectionRef?
    var showTrackNumbers = false
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        let songActions = router.songActions(actions)
        let currentId = player.state.currentSong?.id
        LazyVStack(spacing: 0) {
            if songs.isEmpty {
                EmptyState(message: emptyMessage, systemImage: emptyIcon)
            }
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                TrackRow(song: song, isCurrent: song.id == currentId, showTrackNumber: showTrackNumbers, actions: songActions) {
                    actions.play(songs, startIndex: index, origin: origin)
                }
            }
        }
    }
}
