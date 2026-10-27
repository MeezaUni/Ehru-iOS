import SwiftUI

/// Temporary shell while the Android screens are being ported.
struct RootView: View {
    @Environment(LibraryStore.self) private var library
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
                    ForEach(library.songs) { song in
                        VStack(alignment: .leading) {
                            Text(song.title)
                            Text(song.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("empee3")
            .toolbar {
                Button { showsImporter = true } label: { Image(systemName: "plus") }
            }
            .refreshable { library.scan() }
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
