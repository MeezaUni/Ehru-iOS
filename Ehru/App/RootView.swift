import SwiftUI

/// Temporary shell while the Android screens are being ported.
struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsImporter = false

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            List {
                if let progress = library.scanProgress {
                    Text("Scanning \(progress.scanned) of \(progress.total)…")
                        .foregroundStyle(.secondary)
                }
                Section("Albums (\(library.albums.count))") {
                    ForEach(library.albums) { album in
                        VStack(alignment: .leading) {
                            Text(album.title)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Songs (\(library.songs.count))") {
                    ForEach(Array(library.songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.playSongs(library.songs, startIndex: index)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(song.title)
                                Text(song.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("empee3")
            .toolbar {
                Button { showsImporter = true } label: { Image(systemName: "plus") }
            }
            .refreshable { library.scan() }
            .safeAreaInset(edge: .bottom) {
                if let song = player.state.currentSong {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(song.title).lineLimit(1)
                            Text(song.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { player.skipPrevious() } label: { Image(systemName: "backward.fill") }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.state.isPlaying ? "pause.fill" : "play.fill")
                        }
                        Button { player.skipNext() } label: { Image(systemName: "forward.fill") }
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .alert("Something went wrong", isPresented: $library.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onAppear { library.scan() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.scan() }
        }
    }
}
