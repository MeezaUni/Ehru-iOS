import PhotosUI
import SwiftUI

/// The shared top of a collection page: big cover, title, subtitle, facts, Play / Shuffle.
struct CollectionHeader<Cover: View>: View {
    let title: String
    let subtitle: String?
    let facts: String
    var note: String?
    var coverShape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    var coverInset: CGFloat = 64
    let canPlay: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder let cover: () -> Cover
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { cover() }
                .clipShape(coverShape)
                .frame(maxWidth: ArtworkSize.heroMax)
                .padding(.horizontal, coverInset)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .padding(.bottom, Spacing.lg)
            Text(title).font(.title.weight(.bold)).multilineTextAlignment(.center).lineLimit(2)
            if let subtitle { Text(subtitle).font(.headline).foregroundStyle(palette.onSurface).lineLimit(1) }
            if let note { Text(note).font(.caption).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center) }
            Text(facts).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            HStack(spacing: Spacing.sm) {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity).foregroundStyle(palette.onPrimary)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onShuffle) {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(!canPlay)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.md)
        }
        .padding(.horizontal, Spacing.heroGutter)
        .padding(.top, Spacing.sm)
    }
}

/// "2018 · 12 songs · 43 min"; unknown parts are left out.
func collectionFacts(year: Int? = nil, songs: [Song]) -> String {
    let minutes = songs.reduce(Int64(0)) { $0 + $1.durationMs } / 60_000
    let duration: String? = minutes <= 0 ? nil : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
    let yearText = year.flatMap { (1900...2099).contains($0) ? String($0) : nil }
    return [yearText, countLabel(songs.count, "song"), duration].compactMap { $0 }.joined(separator: " · ")
}

/// An album: cover, facts (and "Lossless" when any track is), Play / Shuffle, its tracks by number.
struct AlbumDetailView: View {
    let albumId: Int64
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router
    @State private var songs: [Song] = []
    @State private var artworkTarget: ArtworkTarget?

    var body: some View {
        let origin = CollectionRef.album(albumId)
        ScrollView {
            if let album = library.album(albumId) {
                let facts = collectionFacts(year: album.year, songs: songs)
                VStack(spacing: 0) {
                    CollectionHeader(title: album.title, subtitle: album.artist, facts: songs.contains(where: \.isLossless) ? "\(facts) · Lossless" : facts,
                                     coverInset: Spacing.md, canPlay: !songs.isEmpty, onPlay: { actions.playInOrder(songs, origin: origin) },
                                     onShuffle: { actions.playShuffled(songs, origin: origin) }) { MotionCoverView(song: library.albumCoverSong[albumId], playing: !router.showsNowPlaying, maxPixels: 900) }
                    TransitionStudioRow(collection: origin).padding(.bottom, Spacing.sm)
                    SongList(songs: songs, origin: origin, showTrackNumbers: true)
                }
            } else {
                EmptyState(message: "This album is no longer in your library.", systemImage: "square.stack")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { songs.reversed().forEach { actions.playNext($0) } } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { songs.forEach { actions.addToQueue($0) } } label: { Label("Add to queue", systemImage: "text.badge.plus") }
                Button { actions.startRadio(.album(albumId)) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                Button { router.songsForPlaylist = songs } label: { Label("Add to playlist", systemImage: "music.note.list") }
                Button { AppServices.shared.fixTags.enqueue(songs); router.open(.autoFixTags) } label: {
                    Label("Fix tags online", systemImage: "wand.and.stars")
                }
                if let album = library.album(albumId) {
                    Button { artworkTarget = .album(album) } label: { Label("Find a cover", systemImage: "photo") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Album options")
        }
        .sheet(item: $artworkTarget) { ArtworkPickerSheet(target: $0) }
        .task(id: library.songs) { songs = (try? library.database.songsOfAlbum(albumId)) ?? [] }
        .artworkFocus(library.albumCoverSong[albumId]?.url)
        .background(alignment: .top) { CoverGlow(url: library.albumCoverSong[albumId]?.url) }
    }
}

/// An artist: photo or monogram, Play / Shuffle, albums split into Albums, EPs and Singles, then
/// features, credited songs and their own tracks.
struct ArtistDetailView: View {
    let artistId: Int64
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router
    @State private var albums: [Album] = []
    @State private var primary: [Song] = []
    @State private var featured: [Song] = []
    @State private var unverified: [Song] = []
    @State private var artworkTarget: ArtworkTarget?

    var body: some View {
        ScrollView {
            if let artist = library.artist(artistId) {
                let all = primary.isEmpty ? featured : primary
                LazyVStack(alignment: .leading, spacing: 0) {
                    CollectionHeader(title: artist.name, subtitle: nil,
                                     facts: "\(countLabel(artist.songCount, "song")) · \(countLabel(artist.albumCount, "album"))",
                                     coverShape: AnyShape(Circle()), canPlay: !all.isEmpty,
                                     onPlay: { actions.playInOrder(all) }, onShuffle: { actions.playShuffled(all) }) {
                        ArtistArtworkView(artist: artist, fontSize: 96)
                    }
                    albumRow("Albums", albums.filter { $0.songCount >= 7 })
                    albumRow("EPs", albums.filter { (3...6).contains($0.songCount) })
                    albumRow("Singles", albums.filter { (1...2).contains($0.songCount) })
                    songSection("Features", featured)
                    songSection("Credited", unverified)
                    songSection("Tracks", primary, numbers: true)
                    if primary.isEmpty && featured.isEmpty {
                        EmptyState(message: "No tracks found for this artist.")
                    }
                }
            } else {
                EmptyState(message: "This artist is no longer in your library.", systemImage: "person")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { primary.reversed().forEach { actions.playNext($0) } } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { primary.forEach { actions.addToQueue($0) } } label: { Label("Add to queue", systemImage: "text.badge.plus") }
                Button { actions.startRadio(.artist(artistId)) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                if let artist = library.artist(artistId) {
                    Button { artworkTarget = .artist(artist) } label: { Label("Find a photo", systemImage: "person.crop.square") }
                    if artist.artworkPath != nil {
                        Button(role: .destructive) { AppServices.shared.artwork.removePhoto(artist) } label: {
                            Label("Remove chosen photo", systemImage: "trash")
                        }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Artist options")
        }
        .sheet(item: $artworkTarget) { ArtworkPickerSheet(target: $0) }
        .task(id: library.songs) { load() }
    }

    private func load() {
        let db = library.database
        albums = (try? db.albumsOfArtist(artistId)) ?? []
        primary = (try? db.songsOfArtist(artistId, role: .primary)) ?? []
        featured = (try? db.songsOfArtist(artistId, role: .featured)) ?? []
        if let key = library.artist(artistId)?.artistKey, !key.isEmpty {
            unverified = (try? db.unverifiedSongs(artistKey: key)) ?? []
        }
    }

    @ViewBuilder
    private func albumRow(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            Shelf(title: title) {
                ForEach(albums) { album in
                    AlbumTile(album: album) { router.open(.album(album.id)) }.frame(width: 128)
                }
            }
            .padding(.bottom, Spacing.sm)
        }
    }

    @ViewBuilder
    private func songSection(_ title: String, _ songs: [Song], numbers: Bool = false) -> some View {
        if !songs.isEmpty {
            SectionHeading(title: title)
            SongList(songs: songs, showTrackNumbers: numbers)
        }
    }
}

/// A playlist: cover, facts, Play / Shuffle, its songs; rename, delete, remove a song.
struct PlaylistDetailView: View {
    let playlistId: Int64
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PlaylistEntry] = []
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var coverItem: PhotosPickerItem?
    @State private var choosingCover = false

    var body: some View {
        let origin = CollectionRef.playlist(playlistId)
        let songs = entries.map(\.song)
        let slots = entries.map(\.position)
        let songActions = playlistSongActions()
        ScrollView {
            if let playlist = library.playlist(playlistId) {
                LazyVStack(spacing: 0) {
                    CollectionHeader(title: playlist.name, subtitle: nil, facts: collectionFacts(songs: songs), canPlay: !songs.isEmpty,
                                     onPlay: { actions.playInOrder(songs, origin: origin, slots: slots) },
                                     onShuffle: { actions.playShuffled(songs, origin: origin, slots: slots) }) { PlaylistCoverView(playlist: playlist) }
                    if songs.count > 1 { TransitionStudioRow(collection: origin).padding(.bottom, Spacing.sm) }
                    if songs.isEmpty {
                        EmptyState(message: "This playlist is empty. Add songs from any song's menu.", systemImage: "music.note.list")
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.position) { index, entry in
                        TrackRow(song: entry.song, isCurrent: entry.song.id == player.state.currentSong?.id, actions: songActions) {
                            actions.play(songs, startIndex: index, origin: origin, slots: slots)
                        }
                    }
                }
            } else {
                EmptyState(message: "This playlist no longer exists.", systemImage: "music.note.list")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { actions.startRadio(.song(songs.first?.id ?? 0)) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                    .disabled(songs.isEmpty)
                Button {
                    newName = library.playlist(playlistId)?.name ?? ""
                    renaming = true
                } label: { Label("Rename", systemImage: "pencil") }
                Button { choosingCover = true } label: { Label("Choose cover", systemImage: "photo") }
                if let playlist = library.playlist(playlistId), playlist.artworkPath != nil {
                    Button { AppServices.shared.artwork.removePlaylistCover(playlist) } label: { Label("Remove cover", systemImage: "photo.badge.minus") }
                }
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Playlist options")
        }
        .photosPicker(isPresented: $choosingCover, selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { _, item in
            guard let item, let playlist = library.playlist(playlistId) else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    do {
                        try AppServices.shared.artwork.setPlaylistCover(data, playlist: playlist)
                    } catch {
                        actions.show("Couldn't save the cover: \(error.localizedDescription)")
                    }
                }
                coverItem = nil
            }
        }
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { try? library.database.renamePlaylist(playlistId, name: newName.trimmed) }
        }
        .confirmationDialog("Delete this playlist?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? library.database.deletePlaylist(playlistId)
                dismiss()
            }
        } message: {
            Text("The songs stay in your library.")
        }
        .task(id: library.playlists) { entries = (try? library.database.playlistEntries(playlistId)) ?? [] }
    }

    private func playlistSongActions() -> SongActions {
        var songActions = router.songActions(actions)
        songActions.removeFromPlaylist = { remove($0) }
        return songActions
    }

    private func remove(_ song: Song) {
        try? library.database.removeSong(song.id, fromPlaylist: playlistId)
    }
}

/// A smart mix's page: generated cover, title, how it was made, facts, Play / Shuffle, its songs.
struct SmartPlaylistDetailView: View {
    let mixKey: String
    @Environment(MixStore.self) private var mixes
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router

    var body: some View {
        let kind = MixKind.fromKey(mixKey)
        let mix = mixes.mix(mixKey)
        let songs = mix.map { actions.songs($0.songIds) } ?? []
        let songActions = router.songActions(actions) { song in
            mixes.setHidden(song.id, true)
            actions.show("\"\(song.title)\" won't be suggested in Smart Playlists")
        }
        ScrollView {
            LazyVStack(spacing: 0) {
                CollectionHeader(title: mix?.title ?? kind?.title ?? "Smart Playlist", subtitle: nil, facts: collectionFacts(songs: songs),
                                 note: mix?.description, canPlay: !songs.isEmpty,
                                 onPlay: { actions.playInOrder(songs) }, onShuffle: { actions.playShuffled(songs) }) {
                    if let kind { MixArtworkView(kind: kind) } else { Color.clear }
                }
                if mixes.mixes != nil && songs.isEmpty {
                    EmptyState(message: "This mix isn't available right now. It comes back as your listening and library grow.")
                }
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    TrackRow(song: song, isCurrent: false, actions: songActions) { actions.play(songs, startIndex: index) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { mixes.start() }
        .id(library.songs.count)
    }
}

/// The top of a collection page washed in its cover's colour, fading into the background (as in
/// Now Playing), so each album feels like its own.
struct CoverGlow: View {
    let url: URL?
    @State private var colors: LyricsColors?
    @State private var artworkRevision = 0

    var body: some View {
        LinearGradient(colors: colors?.cardGradient ?? [.clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.55),
                                        .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .frame(height: 700)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(for: ArtworkLoader.didChange)) { note in
                if note.object as? String == url?.path { artworkRevision += 1 }
            }
            .task(id: "\(url?.path ?? "")|\(artworkRevision)") {
                guard let url else { colors = nil; return }
                let sampled = LyricsColors(await LyricsPaletteCache.shared.palette(for: url))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) { colors = sampled }
            }
    }
}
