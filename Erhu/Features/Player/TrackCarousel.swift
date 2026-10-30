import SwiftUI

/// Now Playing's tracks as cards in depth (Android's TrackCarousel): the current card in front, the
/// previous and next to either side, smaller, turned towards the centre and dimmed, partly visible.
/// A sideways swipe moves the strip with the finger; released past a quarter of a page (or flung)
/// it changes the song, otherwise it springs back. Any track change (swipe, buttons, end of song)
/// slides the strip the same way. [stacked] instead brings the next card forward from a centred
/// depth deck. A vertical drag on the cards pulls the player down ([onPull]).
struct TrackCarousel: View {
    let stacked: Bool
    let previous: QueueEntry?
    let current: QueueEntry?
    let next: QueueEntry?
    var previousTwo: QueueEntry? = nil
    var nextTwo: QueueEntry? = nil
    /// The playing song as the player has it now (its favourite state may be newer than the entry's).
    let currentSong: Song
    /// +1 next, -1 previous: always a change of song, never a restart.
    let skip: (Int) -> CarouselSelection
    let videos: CarouselVideoDeck
    var setBusy: (Bool) -> Void = { _ in }
    /// A downward drag on the cards pulls the player down: the distance while dragging, then the
    /// distance and the predicted end on release.
    var onPull: (CGFloat) -> Void = { _ in }
    var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onPullCancel: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerInMotion) private var playerInMotion
    @Environment(AnimatedArtworkStore.self) private var artwork
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualWorkBudget) private var budget
    @State private var scene = CarouselScene()
    @State private var motion = CarouselMotion()
    @State private var horizontal: Bool?
    @GestureState private var gestureActive = false
    @State private var videoWarmup: Task<Void, Never>?

    private var selection: CarouselSelection { CarouselSelection(previous: previous, current: current, next: next, previousTwo: previousTwo, nextTwo: nextTwo) }
    private func videoRequests() -> [CarouselVideoDeck.Request] {
        guard scenePhase == .active, !reduceMotion, budget.allowsDecorativeMotion else { return [] }
        return scene.items.filter { abs($0.ordinal - scene.center) <= 1 }.compactMap { item in
            artwork.url(for: item.entry.song).map { CarouselVideoDeck.Request(key: item.id, url: $0) }
        }
    }

    private func refreshVideos() {
        videoWarmup?.cancel(); videoWarmup = nil
        // Ready surfaces and recycled neighbours can rebind immediately. Native decoder
        // construction waits until the final cover frame has painted and input is idle.
        guard !playerInMotion, let key = scene.currentKey else { return }
        let requests = videoRequests()
        videos.configure(requests, current: key, prepareNeighbours: !motion.moving, allowNewSessions: false)
        guard !motion.moving, !requests.isEmpty else { return }
        videoWarmup = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard !Task.isCancelled, !motion.moving, !playerInMotion, scene.currentKey == key else { return }
            videos.configure(requests, current: key)
            videoWarmup = nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = CardMetrics(geometry.size)
            let page = CarouselPose.page(width: metrics.cardWidth)
            CarouselStrip(items: scene.items, focus: motion.focus, frontOrdinal: motion.frontOrdinal, stack: motion.stack,
                          viewport: geometry.size,
                          cardSize: CGSize(width: metrics.cardWidth, height: metrics.artSide + metrics.metadataHeight + CardMetrics.padding * 2),
                          reduceMotion: reduceMotion, meter: motion.meter) { item in
                card(item, metrics: metrics)
            }
            .modifier(PlayerCollapseVisibility())
            .contentShape(Rectangle())
            .highPriorityGesture(swipe(page: page))
        }
        .onAppear { refreshVideos() }
        .onChange(of: motion.moving, initial: true) { _, active in
            setBusy(active)
            if active { videoWarmup?.cancel(); videoWarmup = nil }
            else { refreshVideos() }
        }
        .onChange(of: selection, initial: true) { _, next in selectionChanged(next) }
        .onChange(of: stacked) { _, _ in settle() }
        // Media lookup is structural work, never a dependency of the per-touch render path.
        .onChange(of: artwork.saved) { _, _ in refreshVideos() }
        .onChange(of: scenePhase) { _, _ in refreshVideos() }
        .onChange(of: budget) { _, _ in refreshVideos() }
        .onChange(of: reduceMotion) { _, _ in refreshVideos() }
        .onChange(of: playerInMotion) { _, active in
            if !active { refreshVideos(); return }
            videoWarmup?.cancel(); videoWarmup = nil
            guard motion.moving else { return }
            motion.snap(center: scene.center, stacked: stacked)
            scene.settle()
        }
        .onChange(of: gestureActive) { _, active in
            // GestureState also resets on cancellation, when onEnded is never called.
            guard !active, let axis = horizontal else { return }
            horizontal = nil
            motion.endGesture()
            if axis { settle() } else { onPullCancel() }
        }
        .onDisappear { horizontal = nil; videoWarmup?.cancel(); videoWarmup = nil; motion.cancel(); setBusy(false) }
    }

    private func card(_ item: CarouselScene.Item, metrics: CardMetrics) -> some View {
        let distance = CGFloat(item.ordinal) - motion.focus
        let isCurrent = item.id == scene.currentKey
        let song = isCurrent && currentSong.id == item.entry.song.id ? currentSong : item.entry.song
        let session = videos.slots[item.id]?.session
        return CarouselCard(song: song, isCurrent: isCurrent,
                            showsMetadata: isCurrent || !stacked,
                            animatesMotion: CarouselVideoDeck.shouldAnimate(distance: distance, current: isCurrent),
                            reportsArtworkFrame: isCurrent && !motion.moving,
                            videoSession: session, metrics: metrics)
            .equatable()
            .overlay {
                RoundedRectangle(cornerRadius: Radius.large + CardMetrics.padding, style: .continuous)
                    .fill(.black.opacity(Double(min(abs(distance), 1)) * 0.45))
                    .allowsHitTesting(false)
            }
            .modifier(PlayerNeighbourFade(isCurrent: isCurrent))
            .onTapGesture {
                guard !isCurrent, !stacked else { return }
                commitSwipe(item.ordinal > scene.center ? 1 : -1)
            }
            .allowsHitTesting(isCurrent || (!stacked && abs(distance) < 1.5))
    }

    private func swipe(page: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if horizontal == nil { horizontal = abs(value.translation.width) > abs(value.translation.height) }
                guard horizontal == true else { onPull(value.translation.height); return }
                motion.drag(translation: value.translation.width, page: page, center: scene.center,
                            canPrevious: selection.canMove(-1), canNext: selection.canMove(1))
            }
            .onEnded { value in
                defer { horizontal = nil; motion.endGesture() }
                guard horizontal == true else { onPullEnd(value.translation.height, value.predictedEndTranslation.height); return }
                let wanted = CarouselSwipeIntent.direction(translation: value.translation.width,
                                                           predicted: value.predictedEndTranslation.width, page: page)
                let velocity = -value.velocity.width / page
                if selection.canMove(wanted) { commitSwipe(wanted, velocity: velocity) }
                else { settle(velocity: velocity) }
            }
    }

    private func selectionChanged(_ next: CarouselSelection, preferredDirection: Int? = nil, velocity: CGFloat? = nil) {
        guard next != scene.selection else { return }
        let previousID = scene.selection.current?.id
        let adjacent = scene.select(next, preferredDirection: preferredDirection, deferFarPages: motion.moving)
        if previousID == next.current?.id && motion.moving { return }
        if previousID != next.current?.id, adjacent {
            settle(velocity: velocity)
        } else {
            motion.snap(center: scene.center, stacked: stacked)
            scene.settle()
        }
        refreshVideos()
    }

    /// Commit the real queue immediately so card title, index, duration and audio stay together.
    /// Transport defers non-audio side effects while the compositor settles the strip.
    private func commitSwipe(_ direction: Int, velocity: CGFloat? = nil) {
        guard !playerInMotion, selection.canMove(direction) else { settle(); return }
        motion.hold()
        setBusy(true)
        let before = scene.selection.current?.id
        let result = skip(direction)
        selectionChanged(result, preferredDirection: direction, velocity: velocity)
        if result.current?.id == before { settle(velocity: velocity) }
    }

    private func settle(velocity: CGFloat? = nil) {
        motion.settle(center: scene.center, stacked: stacked, reduceMotion: reduceMotion, velocity: velocity) {
            scene.settle()
        }
    }

}

/// The card's size in the room it is given (Android's CarouselCard): the artwork as large as the
/// width (80 % of it, so the neighbours peek in) and the height allow, and the album line only when
/// there is height for it.
struct CardMetrics: Equatable, Sendable {
    static let padding: CGFloat = 10
    let showAlbum: Bool
    let metadataHeight: CGFloat
    let artSide: CGFloat
    var cardWidth: CGFloat { artSide + Self.padding * 2 }

    init(_ size: CGSize) {
        showAlbum = size.height >= 340
        metadataHeight = showAlbum ? 62 + 18 : 62
        artSide = max(min(size.width * 0.8 - Self.padding * 2, size.height - metadataHeight - Self.padding * 2), 140)
    }
}

/// One card at [distance] places from the centre: moved sideways by a share of its width, scaled
/// down and turned towards the centre as it leaves, fading only past one place. With Reduce Motion
/// the cards slide and scale but never turn. [stack] (0…1) blends the separated, angled
/// cards into a centred deck whose incoming card advances from behind.
struct DepthCard: GeometryEffect {
    var distance: CGFloat
    let width: CGFloat
    var stack: CGFloat
    let reduceMotion: Bool
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(distance, stack) }
        set { distance = newValue.first; stack = newValue.second }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let pose = CarouselPose(distance: distance, width: width, stack: stack, reduceMotion: reduceMotion)
        return CarouselProjection.transform(size: size, scale: pose.scale, turn: pose.turn, x: pose.x, y: pose.y)
    }
}

/// One card: the artwork with the title, artist and (room allowing) album beneath, as one rounded
/// card in its own artwork's colours. The current card carries the favourite button; neighbours
/// darken with their distance.
private struct CarouselCard: View, Equatable {
    let song: Song
    let isCurrent: Bool
    let showsMetadata: Bool
    let animatesMotion: Bool
    let reportsArtworkFrame: Bool
    let videoSession: MotionVideoSession?
    let metrics: CardMetrics
    @Environment(LibraryActions.self) private var actions
    @Environment(\.playerArtworkInFlight) private var artworkInFlight
    @Environment(\.palette) private var palette
    @State private var artworkPalette = ArtworkPaletteState()
    @State private var artworkRevision = 0

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.song == rhs.song && lhs.isCurrent == rhs.isCurrent && lhs.showsMetadata == rhs.showsMetadata &&
        lhs.animatesMotion == rhs.animatesMotion && lhs.reportsArtworkFrame == rhs.reportsArtworkFrame &&
        lhs.videoSession === rhs.videoSession && lhs.metrics == rhs.metrics
    }

    var body: some View {
        let colors = LyricsColors(artworkPalette.palette(for: song.url))
        let shape = RoundedRectangle(cornerRadius: Radius.large + CardMetrics.padding, style: .continuous)
        VStack(spacing: 0) {
            Color.clear
                .frame(width: metrics.artSide, height: metrics.artSide)
                .background { if reportsArtworkFrame { Color.clear.playerArtworkFrame(expanded: true) } }
                .overlay {
                    MotionCoverView(song: song, playing: animatesMotion, rendersVideo: videoSession != nil && !artworkInFlight,
                                    maxPixels: isCurrent ? 1200 : 600, animateStill: false,
                                    videoSession: videoSession, tracksScrollVisibility: false)
                        .frame(width: metrics.artSide, height: metrics.artSide)
                        .modifier(PlayerArtworkClip(isCurrent: isCurrent, side: metrics.artSide))
                        .modifier(PlayerArtworkSlotVisibility(hidden: isCurrent && artworkInFlight))
                }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.title2.weight(.bold)).foregroundStyle(colors.content).lineLimit(1)
                    Text(song.artist).font(.subheadline).foregroundStyle(colors.secondary).lineLimit(1)
                    if metrics.showAlbum, !song.album.isBlank {
                        Text(song.album).font(.caption.weight(.medium)).foregroundStyle(colors.secondary.opacity(0.8)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Button { actions.toggleFavorite(song) } label: {
                        Image(systemName: song.isFavorite ? "heart.fill" : "heart").font(.title3)
                            .foregroundStyle(song.isFavorite ? palette.primary : colors.content)
                            .symbolEffect(.bounce, value: song.isFavorite)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(song.isFavorite ? "Remove from favorites" : "Add to favorites")
                }
            }
            .modifier(PlayerChromeFade())
            .opacity(showsMetadata ? 1 : 0)
            .padding(.leading, Spacing.xs)
            .padding(.top, Spacing.sm)
            .frame(width: metrics.artSide, height: metrics.metadataHeight, alignment: .top)
        }
        .padding(CardMetrics.padding)
        .background(CardSurface(colors: colors, shape: shape).modifier(PlayerChromeFade()))
        .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
        .accessibilityElement(children: isCurrent ? .contain : .combine)
        .accessibilityHint(isCurrent ? "" : "Plays this track")
        .onReceive(NotificationCenter.default.publisher(for: ArtworkLoader.didChange)) { note in
            if note.object as? String == song.url.path { artworkRevision += 1 }
        }
        .task(id: "\(song.url.path)|\(artworkRevision)") {
            let revision = ArtworkLoader.shared.revision(for: song.url.path)
            let next = await LyricsPaletteCache.shared.palette(for: song.url)
            guard !Task.isCancelled else { return }
            artworkPalette.set(next, for: song.url, revision: revision)
        }
    }
}

private struct PlayerNeighbourFade: ViewModifier {
    let isCurrent: Bool
    @Environment(PlayerDragState.self) private var drag
    func body(content: Content) -> some View {
        content.modifier(PlayerChromeOpacity(progress: isCurrent ? 1 : drag.progress))
    }
}
