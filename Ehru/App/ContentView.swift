import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsNowPlaying = false

    var body: some View {
        NavigationStack {
            SongsView()
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentSong != nil {
                MiniPlayerView { showsNowPlaying = true }
            }
        }
        .sheet(isPresented: $showsNowPlaying) {
            NowPlayingView()
        }
        .task {
            await library.reload()
        }
        .onChange(of: scenePhase) { _, phase in
            // Files may have been added through the Files app while we were in the background.
            if phase == .active {
                Task { await library.reload() }
            }
        }
    }
}
