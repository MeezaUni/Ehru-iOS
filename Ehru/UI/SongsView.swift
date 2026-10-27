import SwiftUI

struct SongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @State private var searchText = ""
    @State private var showsImporter = false

    private var visibleSongs: [Song] {
        guard !searchText.isEmpty else { return library.songs }
        return library.songs.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.artist.localizedCaseInsensitiveContains(searchText)
                || $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        @Bindable var library = library

        Group {
            if library.songs.isEmpty && !library.isScanning {
                emptyState
            } else {
                songList
            }
        }
        .navigationTitle("Songs")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    player.shuffleAll(library.songs)
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(library.songs.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsImporter = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .alert("Something went wrong", isPresented: $library.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var songList: some View {
        List {
            ForEach(visibleSongs) { song in
                Button {
                    play(song)
                } label: {
                    SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let songs = offsets.map { visibleSongs[$0] }
                for song in songs {
                    library.delete(song)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText)
        .refreshable { await library.reload() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No music yet", systemImage: "music.note")
        } description: {
            Text("Tap + to import songs, or copy them into the empee3 folder under On My iPhone in the Files app.")
        } actions: {
            Button("Import songs") { showsImporter = true }
        }
    }

    private func play(_ song: Song) {
        let songs = visibleSongs
        guard let index = songs.firstIndex(of: song) else { return }
        player.play(songs, startingAt: index)
    }
}
