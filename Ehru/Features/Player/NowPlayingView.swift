import SwiftUI

/// Now Playing: the artwork, title and artist, favourite, the seek bar, transport, shuffle and
/// repeat, the queue, and the overflow menu (radio, playlists, hiding from mixes).
struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryActions.self) private var actions
    @Environment(MixStore.self) private var mixes
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Int64?
    @State private var waveform: WaveformLoad = .loading
    @State private var bookmarks: [Int64] = []
    @State private var showsQueue = false
    @State private var showsLyrics = false
    @State private var showsMarks = false
    @State private var showsVisualizer = false
    @State private var showsEqualizer = false
    @State private var showsAudioDetails = false

    var body: some View {
        let state = player.state
        VStack(spacing: 0) {
            header
            if let song = state.currentSong {
                if showsLyrics {
                    LyricsPanel(song: song)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    Spacer(minLength: Spacing.md)
                    SongArtworkView(song: song, maxPixels: 1200)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                        .scaleEffect(state.isPlaying ? 1 : 0.92)
                        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: state.isPlaying)
                        .padding(.horizontal, Spacing.heroGutter)
                        .frame(maxWidth: ArtworkSize.heroMax)
                        .transition(.opacity)
                    Spacer(minLength: Spacing.lg)
                }
                titleRow(song)
                seekBar(state)
                transport(state)
                bottomRow
            } else {
                Spacer()
                EmptyState(message: "Nothing is playing.", systemImage: "music.note")
                Spacer()
            }
        }
        .padding(.bottom, Spacing.lg)
        .background(backdrop(state.currentSong).ignoresSafeArea())
        .sheet(isPresented: $showsQueue) { QueueSheet() }
        .sheet(isPresented: $showsMarks) { MarksSheet() }
        .sheet(isPresented: $showsAudioDetails) { AudioDetailsView() }
        .fullScreenCover(isPresented: $showsVisualizer) { VisualizerView() }
        .sheet(isPresented: $showsEqualizer) {
            NavigationStack {
                EqualizerView().toolbar { Button("Done") { showsEqualizer = false } }
            }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("Close")
            Spacer()
            if let origin = player.state.currentCollection {
                Text(origin.kind == .album ? "Playing from album" : "Playing from playlist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer()
            menu
        }
        .padding(.horizontal, Spacing.sm)
        .foregroundStyle(palette.onSurface)
    }

    private var menu: some View {
        let song = player.state.currentSong
        let hidden = song.map { mixes.hidden.contains($0.id) } ?? false
        return Menu {
            Section("Track") {
                Button { router.songForDetails = song } label: { Label("Music information", systemImage: "info.circle") }
            }
            Section("Library") {
                Button { addBookmark() } label: { Label("Bookmark this moment", systemImage: "bookmark") }
                Button { showsMarks = true } label: {
                    Label(player.state.abLoop?.enabled == true ? "Bookmarks & A–B loop (on)" : "Bookmarks & A–B loop", systemImage: "bookmark.square")
                }
                Button { if let song { router.songsForPlaylist = [song] } } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
                if let song {
                    Button { mixes.setHidden(song.id, !hidden) } label: {
                        Label(hidden ? "Show in Smart Playlists again" : "Hide from Smart Playlists", systemImage: hidden ? "eye" : "eye.slash")
                    }
                }
            }
            Section("Playback") {
                Button { actions.startRadioFromCurrent() } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
                if let radio = actions.radio, let song, radio.startSongId == song.id || radio.suggested.contains(song.id) {
                    Button { actions.refreshRadio() } label: { Label("New radio picks", systemImage: "arrow.clockwise") }
                }
                Button { showsQueue = true } label: { Label("Queue", systemImage: "list.bullet") }
                Button { showsVisualizer = true } label: { Label("Visualizer", systemImage: "waveform") }
                Button { showsEqualizer = true } label: { Label("Equalizer", systemImage: "slider.vertical.3") }
                Button { showsAudioDetails = true } label: { Label("Audio details", systemImage: "info.circle") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
        }
        .disabled(song == nil)
        .accessibilityLabel("More options")
    }

    private func addBookmark() {
        guard let song = player.state.currentSong else { return }
        let position = player.currentPositionMs()
        do {
            _ = try AppServices.shared.database.addBookmark(songId: song.id, positionMs: position)
            actions.show("Bookmarked \(formatDuration(position))")
        } catch {
            actions.show("Couldn't save the bookmark: \(error.localizedDescription)")
        }
    }

    private func titleRow(_ song: Song) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.title2.weight(.bold)).foregroundStyle(palette.onSurface).lineLimit(1)
                Button {
                    dismiss()
                    if song.artistId != 0 { router.open(.artist(song.artistId)) }
                } label: {
                    Text(song.artist).font(.title3).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button { actions.toggleFavorite(song) } label: {
                Image(systemName: song.isFavorite ? "heart.fill" : "heart").font(.title2).frame(width: 44, height: 44)
            }
            .foregroundStyle(palette.onSurface)
            .accessibilityLabel(song.isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.horizontal, Spacing.heroGutter)
    }

    private func seekBar(_ state: PlaybackState) -> some View {
        let position = scrubbing ?? state.positionMs
        let levels: [Float]? = if case .ready(let values) = waveform { values } else { nil }
        return VStack(spacing: Spacing.xs) {
            WaveformSeekBar(levels: levels, positionMs: state.positionMs, durationMs: state.durationMs, bookmarks: bookmarks,
                            loop: state.abLoop?.songId == state.currentSong?.id ? state.abLoop : nil, previewMs: $scrubbing) {
                player.seek(to: $0)
            }
            HStack {
                Text(formatDuration(position))
                Spacer()
                Text("-" + formatDuration(max(state.durationMs - position, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(.horizontal, Spacing.heroGutter)
        .padding(.top, Spacing.md)
        .task(id: state.currentSong?.id) {
            waveform = .loading
            bookmarks = []
            guard let song = state.currentSong else { return }
            bookmarks = ((try? AppServices.shared.database.bookmarks(songId: song.id)) ?? []).map(\.positionMs)
            waveform = await AppServices.shared.waveforms.waveform(song)
        }
    }

    private func transport(_ state: PlaybackState) -> some View {
        HStack {
            Button { player.setShuffleModeEnabled(!state.shuffleModeEnabled) } label: {
                Image(systemName: "shuffle").font(.title3).foregroundStyle(state.shuffleModeEnabled ? palette.primary : palette.onSurfaceVariant)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(state.shuffleModeEnabled ? "Shuffle on" : "Shuffle off")
            Spacer()
            Button { player.skipPrevious() } label: { Image(systemName: "backward.fill").font(.largeTitle).frame(width: 60, height: 60) }
                .accessibilityLabel("Previous")
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(palette.primary))
            }
            .buttonStyle(PressScaleStyle(scale: 0.92))
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.skipNext() } label: { Image(systemName: "forward.fill").font(.largeTitle).frame(width: 60, height: 60) }
                .accessibilityLabel("Next")
            Spacer()
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: state.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(state.repeatMode == .off ? palette.onSurfaceVariant : palette.primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Repeat \(state.repeatMode == .off ? "off" : state.repeatMode == .one ? "one" : "all")")
        }
        .foregroundStyle(palette.onSurface)
        .padding(.horizontal, Spacing.heroGutter)
        .padding(.vertical, Spacing.md)
    }

    private var bottomRow: some View {
        HStack {
            Button { if let song = player.state.currentSong { router.songsForPlaylist = [song] } } label: {
                Image(systemName: "plus").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Add to playlist")
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.25)) { showsLyrics.toggle() } } label: {
                Image(systemName: showsLyrics ? "quote.bubble.fill" : "quote.bubble").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel(showsLyrics ? "Hide lyrics" : "Show lyrics")
            Spacer()
            Button { showsQueue = true } label: { Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Queue")
        }
        .foregroundStyle(palette.onSurface)
        .padding(.horizontal, Spacing.heroGutter)
    }

    /// The artwork, blurred, behind everything.
    private func backdrop(_ song: Song?) -> some View {
        ZStack {
            palette.background
            if let song {
                SongArtworkView(song: song, maxPixels: 200)
                    .blur(radius: 60)
                    .opacity(0.55)
                    .scaleEffect(1.4)
            }
            palette.background.opacity(0.35)
        }
    }
}

/// The queue and what has played this session: reorder, remove (with undo), shuffle upcoming,
/// save as a playlist, play a history entry again.
struct QueueSheet: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryActions.self) private var actions
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var savingName = ""
    @State private var saving = false

    var body: some View {
        let state = player.state
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Page", selection: $page) {
                    Text("Queue (\(state.queue.count))").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.sm)
                if page == 0 { queue(state) } else { history(state) }
            }
            .navigationTitle(page == 0 ? "Queue" : "History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if page == 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button { if !player.shuffleUpcoming() { actions.show("Fewer than two songs are coming up") } } label: {
                                Label("Shuffle upcoming", systemImage: "shuffle")
                            }
                            Button { saving = true } label: { Label("Save as playlist", systemImage: "square.and.arrow.down") }
                            Button { if !player.undoQueueRemoval() { actions.show("Nothing to undo") } } label: {
                                Label("Undo removal", systemImage: "arrow.uturn.backward")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .alert("Save queue as playlist", isPresented: $saving) {
                TextField("Name", text: $savingName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    actions.createPlaylist(savingName, songs: player.state.queue.map(\.song))
                    savingName = ""
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func queue(_ state: PlaybackState) -> some View {
        List {
            if state.queue.isEmpty {
                Text("No track playing").foregroundStyle(palette.onSurfaceVariant)
            }
            ForEach(Array(state.queue.enumerated()), id: \.element.id) { index, entry in
                Button { player.skipToQueueItem(index) } label: {
                    row(entry.song, highlighted: index == state.currentIndex)
                }
                .buttonStyle(.plain)
                .opacity(index < state.currentIndex ? 0.55 : 1)
            }
            .onDelete { offsets in offsets.sorted(by: >).forEach { player.removeFromQueue($0) } }
            .onMove { source, destination in
                guard let from = source.first else { return }
                player.reorder(from: from, to: destination > from ? destination - 1 : destination)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
    }

    private func history(_ state: PlaybackState) -> some View {
        List {
            if state.history.isEmpty {
                Text("Songs you play this session show up here.").foregroundStyle(palette.onSurfaceVariant)
            }
            ForEach(state.history) { entry in
                HStack {
                    row(entry.song, highlighted: false)
                    Button { player.playFromHistory(entry.entryId) } label: { Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(entry.song.title) again")
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(_ song: Song, highlighted: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            SongArtworkView(song: song, maxPixels: 132)
                .frame(width: ArtworkSize.compact, height: ArtworkSize.compact)
                .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.subheadline.weight(.semibold)).foregroundStyle(highlighted ? Color.accentColor : palette.onSurface).lineLimit(1)
                Text(song.artist).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
