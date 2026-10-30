import SwiftUI

/// Now Playing (Android's NowPlayingScreen): one scrolling page. The first screen is the cover
/// carousel, the progress row and the controls, with the lyrics heading just showing at the bottom;
/// the lyrics card follows below and expands to full screen. The overflow menu holds information,
/// bookmarks, playlists, mixes, radio, the queue, the visualizer, the equalizer and audio details.
struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryActions.self) private var actions
    @Environment(MixStore.self) private var mixes
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette
    private var videoSession: MotionVideoSession? { player.coverVideos.currentSession }
    @Environment(\.playerArtworkFrames) private var artworkFrames
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artworkTarget: ArtworkTarget?
    let drag: PlayerDragState
    @State private var showsQueue = false
    @State private var showsLyrics = false
    @State private var showsMarks = false
    @State private var showsVisualizer = false
    @State private var showsEqualizer = false
    @State private var showsAudioDetails = false
    /// The neighbour cards side by side (the default each time) or stacked behind the current one.
    @State private var stacked = false
    @GestureState private var headerPullActive = false

    /// How much of the lyrics card shows at the bottom of the first screen.
    private static let lyricsPeek: CGFloat = 64

    var body: some View {
        let state = player.state
        let neighborhood = carouselSelection(state)
        VStack(spacing: 0) {
            header.modifier(PlayerChromeFade())
            if let current = state.currentSong {
                // Queue snapshots keep playback stable; favorite/tag changes come from the
                // current library so a swipe-to-like is reflected on the playing card too.
                let song = library.songs.first(where: { $0.id == current.id }) ?? current
                GeometryReader { geometry in
                    let viewport = geometry.size.height
                    ScrollView {
                        VStack(spacing: 0) {
                            VStack(spacing: Spacing.md) {
                                TrackCarousel(stacked: stacked, previous: previousEntry(state), current: state.currentEntry,
                                              next: nextEntry(state), previousTwo: neighborhood.previousTwo, nextTwo: neighborhood.nextTwo,
                                              currentSong: song,
                                              skip: { direction in
                                                  if direction > 0 { player.skipNext() } else { player.skipToPreviousItem() }
                                                  return carouselSelection(player.state)
                                              }, videos: player.coverVideos,
                                              setBusy: { player.setVisualMotion(.carousel, active: $0) },
                                              onPull: pulled, onPullEnd: pullEnded,
                                              onPullCancel: { drag.cancelGesture(reduceMotion: reduceMotion) })
                                    .frame(maxHeight: .infinity)
                                VStack(spacing: Spacing.sm) {
                                    ProgressSection(song: song)
                                    controls(state)
                                }
                                .modifier(PlayerChromeFade())
                                .padding(.horizontal, Spacing.heroGutter)
                            }
                            .padding(.top, Spacing.sm)
                            .padding(.bottom, Spacing.md)
                            .frame(height: max(viewport - Self.lyricsPeek, 420))
                            LyricsPanel(song: song) { showsLyrics = true }
                                .modifier(PlayerChromeFade())
                                .frame(height: min(max(viewport * 0.62, 300), 560))
                                .padding(.horizontal, Spacing.heroGutter)
                            Spacer().frame(height: Spacing.xl)
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                Spacer()
                EmptyState(message: "Nothing is playing. Pick a song from your library.", systemImage: "music.note")
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PlayerForegroundMotion(drag: drag))
        .overlay {
            if let song = state.currentSong {
                PlayerArtworkFlight(drag: drag, frames: artworkFrames) {
                    MotionCoverView(song: song, rendersVideo: videoSession != nil && drag.isMoving && drag.isReady, animateStill: false, suspended: true, videoSession: videoSession, tracksScrollVisibility: false)
                        .modifier(PlayerArtworkClip(isCurrent: true, side: artworkFrames.expanded.width))
                }
            }
        }
        .onChange(of: headerPullActive) { _, active in
            if !active { drag.cancelGesture(reduceMotion: reduceMotion) }
        }
        .onChange(of: drag.isMoving, initial: true) { _, active in player.setVisualMotion(.presentation, active: active) }
        .onDisappear {
            player.setVisualMotion(.presentation, active: false)
            player.setVisualMotion(.carousel, active: false)
            player.coverVideos.retainCurrent()
        }
        .background(backdrop(state.currentSong).ignoresSafeArea().modifier(PlayerBackdropFade(drag: drag)))
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: actions.message)
        .routerSheets(active: true)
        .sheet(isPresented: $showsQueue) { QueueSheet() }
        .sheet(item: $artworkTarget) { ArtworkPickerSheet(target: $0) }
        .sheet(isPresented: $showsMarks) { MarksSheet() }
        .sheet(isPresented: $showsAudioDetails) { AudioDetailsView() }
        .fullScreenCover(isPresented: $showsVisualizer) { VisualizerView() }
        .fullScreenCover(isPresented: $showsLyrics) { ExpandedLyrics(previous: previous, next: next) }
        .sheet(isPresented: $showsEqualizer) {
            NavigationStack {
                EqualizerView().toolbar { Button("Done") { showsEqualizer = false } }
            }
        }
    }

    /// The header and the cover carousel pull the player down (Android's collapse drag).
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($headerPullActive) { _, active, _ in active = true }
            .onChanged { pulled($0.translation.height) }
            .onEnded { pullEnded($0.translation.height, $0.predictedEndTranslation.height) }
    }

    private func pulled(_ distance: CGFloat) { drag.update(distance) }

    private func pullEnded(_ distance: CGFloat, _ predicted: CGFloat) {
        if distance > 140 || predicted > 420 {
            close(velocity: (predicted - distance) * 4)
        } else {
            drag.restore(reduceMotion: reduceMotion)
        }
    }

    private func close(velocity: CGFloat? = nil) {
        drag.beginDismissal(reduceMotion: reduceMotion, velocity: velocity)
        withAnimation(.smooth(duration: 0.32)) { router.showsNowPlaying = false }
    }

    private func previousEntry(_ state: PlaybackState) -> QueueEntry? {
        PlayOrder.previous(before: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode).map { state.queue[$0] }
    }

    private func nextEntry(_ state: PlaybackState) -> QueueEntry? {
        PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: true).map { state.queue[$0] }
    }

    private func carouselSelection(_ state: PlaybackState) -> CarouselSelection {
        guard state.currentEntry != nil else { return CarouselSelection(previous: nil, current: nil, next: nil) }
        let previous = PlayOrder.previous(before: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode)
        let next = PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: true)
        let previousTwo = previous.flatMap { PlayOrder.previous(before: $0, count: state.queue.count, repeatMode: state.repeatMode) }
        let nextTwo = next.flatMap { PlayOrder.next(after: $0, count: state.queue.count, repeatMode: state.repeatMode, userSkip: true) }
        return CarouselSelection(previous: previous.map { state.queue[$0] }, current: state.currentEntry,
                                 next: next.map { state.queue[$0] }, previousTwo: previousTwo.map { state.queue[$0] },
                                 nextTwo: nextTwo.map { state.queue[$0] })
    }

    /// Previous restarts the song after a few seconds; otherwise both buttons slide the carousel
    /// like a swipe.
    private func previous() {
        if player.currentPositionMs() > 3_000 || previousEntry(player.state) == nil {
            player.skipPrevious()
        } else {
            player.skipToPreviousItem()
        }
    }

    private func next() { player.skipNext() }

    @ViewBuilder
    private var toast: some View {
        if let message = actions.message {
            LibraryActionToast(text: message, id: actions.messageID)
                .padding(.bottom, Spacing.xl)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Button { close() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            Button {
                guard let source = player.state.currentEntry?.source else { return }
                drag.beginDismissal(reduceMotion: reduceMotion)
                withAnimation(.smooth(duration: 0.32)) { router.reveal(source) }
            } label: {
                Text(playbackSourceTitle)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens where this music was started")
            .disabled(player.state.currentEntry == nil)
            menu
        }
        .padding(.horizontal, Spacing.xs)
        .foregroundStyle(palette.onSurface)
        .contentShape(Rectangle())
        .gesture(pullGesture)
    }

    private var playbackSourceTitle: String {
        guard let source = player.state.currentEntry?.source else { return "Your music" }
        switch source {
        case .album(let id): return library.album(id)?.title ?? "Album unavailable"
        case .playlist(let id): return library.playlist(id)?.name ?? "Playlist unavailable"
        case .artist(let id): return library.artist(id)?.name ?? "Artist unavailable"
        case .smartPlaylist(let key): return mixes.mix(key)?.title ?? MixKind.fromKey(key)?.title ?? "Smart playlist"
        case .library: return "Library"
        case .favorites: return "Liked Songs"
        case .vybe: return "VYBE"
        }
    }

    private var menu: some View {
        let song = player.state.currentSong
        let hidden = song.map { mixes.hidden.contains($0.id) } ?? false
        return Menu {
            Section("Track") {
                Button { router.songForDetails = song } label: { Label("Music information", systemImage: "info.circle") }
                Button { showsAudioDetails = true } label: { Label("Audio details", systemImage: "waveform.badge.magnifyingglass") }
                if let album = song.flatMap({ library.album($0.albumId) }) {
                    Button { artworkTarget = .album(album) } label: { Label("Find a better cover", systemImage: "photo.badge.magnifyingglass") }
                }
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
                Button { showsQueue = true } label: { Label("Queue", systemImage: "music.note.list") }
                Button { showsVisualizer = true } label: { Label("Visualizer", systemImage: "waveform") }
                Button { showsEqualizer = true } label: { Label("Equalizer", systemImage: "slider.vertical.3") }
            }
        } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.title3.weight(.semibold))
                .frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .menuStyle(.button)
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

    /// Shuffle, previous, play / pause, next, repeat; under shuffle, play / pause and repeat: add to
    /// a playlist, the album stack toggle and the queue. One grid of five equal columns.
    private func controls(_ state: PlaybackState) -> some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: 0) {
                slot {
                    ToggleIcon(systemImage: "shuffle", active: state.shuffleModeEnabled) { player.setShuffleModeEnabled(!state.shuffleModeEnabled) }
                        .accessibilityLabel(state.shuffleModeEnabled ? "Shuffle on" : "Shuffle off")
                }
                slot {
                    Button(action: previous) { Image(systemName: "backward.end.fill").font(.system(size: 30)).frame(width: 52, height: 52).contentShape(Rectangle()) }
                        .buttonStyle(PressScaleStyle(scale: 0.88))
                        .accessibilityLabel("Previous")
                }
                slot {
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(palette.onPrimary)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 80, height: 80)
                            .background(Circle().fill(palette.primary))
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.92))
                    .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
                }
                slot {
                    Button(action: next) { Image(systemName: "forward.end.fill").font(.system(size: 30)).frame(width: 52, height: 52).contentShape(Rectangle()) }
                        .buttonStyle(PressScaleStyle(scale: 0.88))
                        .accessibilityLabel("Next")
                }
                slot {
                    ToggleIcon(systemImage: state.repeatMode == .one ? "repeat.1" : "repeat", active: state.repeatMode != .off) { player.cycleRepeatMode() }
                        .accessibilityLabel("Repeat \(state.repeatMode == .off ? "off" : state.repeatMode == .one ? "one" : "all")")
                }
            }
            HStack(spacing: 0) {
                slot {
                    Button { if let song = player.state.currentSong { router.songsForPlaylist = [song] } } label: {
                        Image(systemName: "plus").font(.title3).frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add to playlist")
                }
                slot {}
                slot {
                    Button { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { stacked.toggle() } } label: {
                        Image(systemName: stacked ? "rectangle.split.3x1.fill" : "square.3.layers.3d")
                            .font(.title3).contentTransition(.symbolEffect(.replace))
                            .frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .accessibilityLabel(stacked ? "Show albums side by side" : "Stack background albums")
                }
                slot {}
                slot {
                    Button { showsQueue = true } label: {
                        Image(systemName: "music.note.list").font(.title3).frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Queue")
                }
            }
        }
        .foregroundStyle(palette.onSurface)
    }

    private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity)
    }

    /// The artwork, strongly blurred and dimmed, behind everything.
    private func backdrop(_ song: Song?) -> some View {
        ZStack {
            palette.background
            if let song {
                SongArtworkView(song: song, maxPixels: 200)
                    .blur(radius: 70)
                    .scaleEffect(1.5)
                    .opacity(0.7)
            }
            Color.black.opacity(0.42)
        }
    }
}

/// A toggle in the controls (shuffle, repeat): its icon dimmed when off, on a soft disc when on.
private struct ToggleIcon: View {
    let systemImage: String
    let active: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title3.weight(.semibold))
                .foregroundStyle(active ? palette.primary : palette.onSurface.opacity(0.6))
                .frame(width: 48, height: 48)
                .background(Circle().fill(palette.primary.opacity(active ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .animation(.easeInOut(duration: 0.2), value: active)
    }
}

/// Elapsed · position in the queue · length over the line seek bar. On its own, so only it redraws
/// as the song plays.
private struct ProgressSection: View {
    let song: Song
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette
    @State private var previewMs: Int64?
    @State private var bookmarks: [Int64] = []
    @State private var accent: Color?

    var body: some View {
        let state = player.state
        let duration = max(state.durationMs > 0 ? state.durationMs : song.durationMs, 1)
        VStack(spacing: 2) {
            HStack {
                Text(formatDuration(min(max(previewMs ?? player.clock.positionMs, 0), duration)))
                Spacer()
                if state.queue.count > 1 {
                    Text("\(state.currentIndex + 1) / \(state.queue.count)").font(.caption2.weight(.medium))
                    Spacer()
                }
                Text(formatDuration(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.onSurfaceVariant)
            LineSeekBar(durationMs: duration, isPlaying: state.isPlaying, bookmarks: bookmarks,
                        loop: state.abLoop?.songId == song.id ? state.abLoop : nil, accent: accent ?? palette.primary,
                        previewMs: $previewMs) { player.seek(to: $0) }
        }
        .task(id: song.id) {
            bookmarks = ((try? AppServices.shared.database.bookmarks(songId: song.id)) ?? []).map(\.positionMs)
            // The artwork's accent (chosen to read on a dark surface) on the player's dark backdrop.
            let sampled = await LyricsPaletteCache.shared.palette(for: song.url)
            let colors = LyricsColors(sampled)
            withAnimation(.easeInOut(duration: 0.4)) { accent = relativeLuminance(sampled.surface) < 0.4 ? colors.accent : nil }
        }
    }
}

/// The full lyrics over Now Playing (Android's ExpandedLyrics): the song at the top, the lyrics in
/// the artwork's colours on its gradient, previous / play / next underneath.
private struct ExpandedLyrics: View {
    let previous: () -> Void
    let next: () -> Void
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var artworkPalette = ArtworkPaletteState()

    var body: some View {
        let state = player.state
        let colors = LyricsColors(artworkPalette.palette(for: state.currentSong?.url))
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .accessibilityLabel("Close lyrics")
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.currentSong?.title ?? "").font(.headline).foregroundStyle(colors.content).lineLimit(1)
                    Text(state.currentSong?.artist ?? "").font(.caption).foregroundStyle(colors.secondary).lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(colors.content)
            .padding(.leading, Spacing.xs)
            .padding(.trailing, Spacing.lg)
            .padding(.top, Spacing.sm)
            if let song = state.currentSong {
                LyricsPanel(song: song).frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            HStack {
                Button(action: previous) { Image(systemName: "backward.end.fill").font(.system(size: 28)).frame(width: 56, height: 56).contentShape(Rectangle()) }
                    .accessibilityLabel("Previous")
                    .frame(maxWidth: .infinity)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30)).contentTransition(.symbolEffect(.replace))
                        .frame(width: 56, height: 56).contentShape(Rectangle())
                }
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
                .frame(maxWidth: .infinity)
                Button(action: next) { Image(systemName: "forward.end.fill").font(.system(size: 28)).frame(width: 56, height: 56).contentShape(Rectangle()) }
                    .accessibilityLabel("Next")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(colors.content)
            .padding(.vertical, Spacing.sm)
        }
        .buttonStyle(.plain)
        .background(LinearGradient(colors: colors.gradient, startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .task(id: state.currentSong?.url) {
            guard let url = state.currentSong?.url else { return }
            let revision = ArtworkLoader.shared.revision(for: url.path)
            let next = await LyricsPaletteCache.shared.palette(for: url)
            guard !Task.isCancelled else { return }
            artworkPalette.set(next, for: url, revision: revision)
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
    @State private var feedback: String?
    @State private var feedbackID = UUID()

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
                            Button { if !player.shuffleUpcoming() { showFeedback("Fewer than two songs are coming up") } } label: {
                                Label("Shuffle upcoming", systemImage: "shuffle")
                            }
                            Button { saving = true } label: { Label("Save as playlist", systemImage: "square.and.arrow.down") }
                            Button { showFeedback(player.undoQueueRemoval() ? "Removal undone" : "Nothing to undo") } label: {
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
        .overlay(alignment: .bottom) {
            if let feedback { Toast(text: feedback).padding(.horizontal, Spacing.gutter).padding(.bottom, Spacing.md).allowsHitTesting(false) }
        }
        .task(id: feedbackID) {
            guard feedback != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            feedback = nil
        }
        .presentationDetents([.medium, .large])
    }

    private func showFeedback(_ text: String) { feedback = text; feedbackID = UUID() }

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
    var enabled = true
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerInMotion) private var playerInMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualWorkBudget) private var budget
    /// One full drift cycle.
    private static let period: Double = 24

    func body(content: Content) -> some View {
        if enabled && settings.movingArtwork && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: !isPlaying || playerInMotion || scenePhase != .active || !budget.allowsDecorativeMotion)) { context in
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
