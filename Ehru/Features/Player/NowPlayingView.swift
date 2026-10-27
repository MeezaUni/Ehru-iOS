import SwiftUI

/// Now Playing (Android's layout): a scrolling page with the queue's covers as swipeable cards
/// (the neighbours peeking at the sides), the time row and seek bar, transport, the add /
/// visualizer / queue row, and the lyrics card, which expands to full screen. The overflow menu
/// holds radio, bookmarks, playlists and hiding from mixes.
struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryActions.self) private var actions
    @Environment(MixStore.self) private var mixes
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
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
                ScrollView {
                    VStack(spacing: 0) {
                        CoverCarousel()
                            .padding(.top, Spacing.sm)
                        SeekSection(song: song)
                        transport(state)
                        secondaryRow
                        lyricsCard(song)
                    }
                    .padding(.bottom, Spacing.xxl)
                }
                .scrollIndicators(.hidden)
            } else {
                Spacer()
                EmptyState(message: "Nothing is playing.", systemImage: "music.note")
                Spacer()
            }
        }
        .background(backdrop(state.currentSong).ignoresSafeArea())
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: actions.message)
        .routerSheets(active: true)
        .sheet(isPresented: $showsQueue) { QueueSheet() }
        .sheet(isPresented: $showsMarks) { MarksSheet() }
        .sheet(isPresented: $showsAudioDetails) { AudioDetailsView() }
        .fullScreenCover(isPresented: $showsVisualizer) { VisualizerView() }
        .fullScreenCover(isPresented: $showsLyrics) { LyricsFullScreen() }
        .sheet(isPresented: $showsEqualizer) {
            NavigationStack {
                EqualizerView().toolbar { Button("Done") { showsEqualizer = false } }
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = actions.message {
            Toast(text: message)
                .padding(.bottom, Spacing.xl)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { if actions.message == message { actions.message = nil } }
                }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 0) {
                Text("Now Playing").font(.title3.weight(.semibold))
                if let origin = player.state.currentCollection {
                    Text(origin.kind == .album ? "Playing from album" : "Playing from playlist")
                        .font(.caption)
                        .foregroundStyle(palette.onSurfaceVariant)
                }
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

    private func transport(_ state: PlaybackState) -> some View {
        HStack {
            Button { player.setShuffleModeEnabled(!state.shuffleModeEnabled) } label: {
                Image(systemName: "shuffle").font(.title3).foregroundStyle(state.shuffleModeEnabled ? palette.primary : palette.onSurfaceVariant)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(state.shuffleModeEnabled ? "Shuffle on" : "Shuffle off")
            Spacer()
            Button { player.skipPrevious() } label: { Image(systemName: "backward.end.fill").font(.title).frame(width: 56, height: 56) }
                .accessibilityLabel("Previous")
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(palette.primary))
            }
            .buttonStyle(PressScaleStyle(scale: 0.92))
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.skipNext() } label: { Image(systemName: "forward.end.fill").font(.title).frame(width: 56, height: 56) }
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

    private var secondaryRow: some View {
        HStack {
            Button { if let song = player.state.currentSong { router.songsForPlaylist = [song] } } label: {
                Image(systemName: "plus").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Add to playlist")
            Spacer()
            Button { showsVisualizer = true } label: {
                Image(systemName: "square.3.layers.3d").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Visualizer")
            Spacer()
            Button { showsQueue = true } label: { Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Queue")
        }
        .foregroundStyle(palette.onSurface)
        .padding(.horizontal, Spacing.heroGutter + Spacing.sm)
    }

    /// The lyrics in a card under the controls (scroll down to read along); the corner button
    /// opens them full screen.
    private func lyricsCard(_ song: Song) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lyrics").font(.subheadline.weight(.semibold))
                Spacer()
                Button { showsLyrics = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open lyrics full screen")
            }
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, Spacing.lg + Spacing.xs)
            LyricsPanel(song: song)
                .frame(height: 420)
        }
        .padding(.top, Spacing.lg)
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

/// The queue's covers as cards in a row: the playing one in the middle with its title, artist,
/// album and favourite, the previous and next peeking at the sides. Swiping to a card plays it.
private struct CoverCarousel: View {
    @Environment(PlayerController.self) private var player
    @State private var shown: UUID?

    var body: some View {
        let state = player.state
        ScrollView(.horizontal) {
            LazyHStack(spacing: Spacing.md) {
                ForEach(Array(state.queue.enumerated()), id: \.element.id) { index, entry in
                    let current = index == state.currentIndex
                    CoverCard(song: current ? state.currentSong ?? entry.song : entry.song, isCurrent: current, isPlaying: current && state.isPlaying)
                        .containerRelativeFrame(.horizontal)
                        .scrollTransition(axis: .horizontal) { content, phase in
                            content.scaleEffect(phase.isIdentity ? 1 : 0.9).opacity(phase.isIdentity ? 1 : 0.6)
                        }
                        .id(entry.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 36, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $shown)
        .onAppear { shown = state.currentEntry?.id }
        .onChange(of: state.currentEntry?.id) { _, id in
            guard shown != id else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { shown = id }
        }
        .task(id: shown) {
            // Once the swipe settles on another card, not on every card it passes.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let id = shown, id != player.state.currentEntry?.id,
                  let index = player.state.queue.firstIndex(where: { $0.id == id }) else { return }
            player.skipToQueueItem(index)
        }
    }
}

private struct CoverCard: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SongArtworkView(song: song, maxPixels: 1200)
                .aspectRatio(1, contentMode: .fit)
                .modifier(MovingArtwork(isPlaying: isPlaying))
                .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            HStack(alignment: .center, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.title2.weight(.bold)).foregroundStyle(palette.onSurface).lineLimit(1)
                    Button {
                        guard song.artistId != 0 else { return }
                        dismiss()
                        router.open(.artist(song.artistId))
                    } label: {
                        Text(song.artist).font(.body).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    if !song.album.isEmpty {
                        Text(song.album).font(.footnote).foregroundStyle(palette.onSurfaceVariant.opacity(0.8)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button { actions.toggleFavorite(song) } label: {
                    Image(systemName: song.isFavorite ? "heart.fill" : "heart").font(.title2).frame(width: 44, height: 44)
                }
                .foregroundStyle(song.isFavorite ? palette.primary : palette.onSurface)
                .accessibilityLabel(song.isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            .padding(.horizontal, Spacing.xs)
        }
        .padding(Spacing.md)
        .background(RoundedRectangle(cornerRadius: Radius.large + Spacing.md, style: .continuous).fill(palette.surface.opacity(0.55)))
        .shadow(color: .black.opacity(isCurrent ? 0.3 : 0.15), radius: 18, y: 10)
    }
}

/// Elapsed · position in the queue · length, and the waveform seek bar. On its own so only it
/// redraws as the song plays.
private struct SeekSection: View {
    let song: Song
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette
    @State private var scrubbing: Int64?
    @State private var waveform: WaveformLoad = .loading
    @State private var bookmarks: [Int64] = []

    private var levels: [Float]? {
        if case .ready(let values) = waveform { values } else { nil }
    }

    var body: some View {
        let state = player.state
        let live = player.clock.positionMs
        let position = scrubbing ?? live
        VStack(spacing: Spacing.xs) {
            HStack {
                Text(formatDuration(position))
                Spacer()
                Text("\(state.currentIndex + 1) / \(state.queue.count)")
                Spacer()
                Text(formatDuration(state.durationMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.onSurfaceVariant)
            WaveformSeekBar(levels: levels, positionMs: live, durationMs: state.durationMs, bookmarks: bookmarks,
                            loop: state.abLoop?.songId == song.id ? state.abLoop : nil, previewMs: $scrubbing) {
                player.seek(to: $0)
            }
        }
        .padding(.horizontal, Spacing.heroGutter)
        .padding(.top, Spacing.lg)
        .task(id: song.id) {
            waveform = .loading
            bookmarks = ((try? AppServices.shared.database.bookmarks(songId: song.id)) ?? []).map(\.positionMs)
            waveform = await AppServices.shared.waveforms.waveform(song)
        }
    }
}

/// The lyrics full screen (Android's expanded lyrics): the song at the top, the lyrics, and
/// previous / play / next at the bottom.
private struct LyricsFullScreen: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = player.state
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close lyrics")
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.currentSong?.title ?? "").font(.headline).lineLimit(1)
                    Text(state.currentSong?.artist ?? "").font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, Spacing.sm)
            if let song = state.currentSong {
                LyricsPanel(song: song).frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            HStack(spacing: Spacing.xxl * 2) {
                Button { player.skipPrevious() } label: { Image(systemName: "backward.end.fill").font(.title2) }
                    .accessibilityLabel("Previous")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .bold))
                }
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
                Button { player.skipNext() } label: { Image(systemName: "forward.end.fill").font(.title2) }
                    .accessibilityLabel("Next")
            }
            .foregroundStyle(palette.onSurface)
            .padding(.vertical, Spacing.lg)
        }
        .background(palette.background.ignoresSafeArea())
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

/// A slow drift and zoom of the artwork while music plays, so the cover feels alive without being
/// a video. Still when paused, when turned off in Settings, or with Reduce Motion on.
struct MovingArtwork: ViewModifier {
    let isPlaying: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One full drift cycle.
    private static let period: Double = 24

    func body(content: Content) -> some View {
        if settings.movingArtwork && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate / Self.period * 2 * .pi
                GeometryReader { geometry in
                    let travel = geometry.size.width * 0.03
                    content
                        .scaleEffect(1.08 + 0.02 * CGFloat(sin(phase * 0.5)))
                        .offset(x: travel * CGFloat(cos(phase)), y: travel * CGFloat(sin(phase)))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        } else {
            content
        }
    }
}
