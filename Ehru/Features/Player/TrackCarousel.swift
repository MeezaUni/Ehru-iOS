import SwiftUI

/// Now Playing's tracks as cards in depth (Android's TrackCarousel): the current card in front, the
/// previous and next to either side, smaller, turned towards the centre and dimmed, partly visible.
/// A sideways swipe moves the strip with the finger; released past a quarter of a page (or flung)
/// it changes the song, otherwise it springs back. Any track change (swipe, buttons, end of song)
/// slides the strip the same way. [stacked] gathers the neighbours into one card behind the current
/// one instead. A vertical drag on the cards pulls the player down ([onPull]).
struct TrackCarousel: View {
    let stacked: Bool
    let previous: QueueEntry?
    let current: QueueEntry?
    let next: QueueEntry?
    var previousTwo: QueueEntry? = nil
    var nextTwo: QueueEntry? = nil
    /// The playing song as the player has it now (its favourite state may be newer than the entry's).
    let currentSong: Song
    let isPlaying: Bool
    /// +1 next, -1 previous: always a change of song, never a restart.
    let skip: (Int) -> CarouselSelection
    let videoSession: MotionVideoSession
    var setBusy: (Bool) -> Void = { _ in }
    /// A downward drag on the cards pulls the player down: the distance while dragging, then the
    /// distance and the predicted end on release.
    var onPull: (CGFloat) -> Void = { _ in }
    var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerInMotion) private var playerInMotion
    @State private var scene = CarouselScene()
    @State private var motion = CarouselMotion()
    @State private var horizontal: Bool?
    @State private var videoKey: String?

    private var selection: CarouselSelection { CarouselSelection(previous: previous, current: current, next: next, previousTwo: previousTwo, nextTwo: nextTwo) }

    var body: some View {
        GeometryReader { geometry in
            let metrics = CardMetrics(geometry.size)
            let page = CarouselPose.page(width: metrics.cardWidth)
            CarouselStrip(items: scene.items, focus: motion.focus, frontOrdinal: motion.frontOrdinal, stack: motion.stack,
                          viewport: geometry.size,
                          cardSize: CGSize(width: metrics.cardWidth, height: metrics.artSide + metrics.metadataHeight + CardMetrics.padding * 2),
                          hideLeft: next != nil, reduceMotion: reduceMotion, meter: motion.meter) { item in
                card(item, metrics: metrics)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(swipe(page: page))
        }
        .onChange(of: motion.moving, initial: true) { _, active in setBusy(active) }
        .onChange(of: selection, initial: true) { _, next in selectionChanged(next) }
        .onChange(of: stacked) { _, _ in settle() }
        .onChange(of: playerInMotion) { _, active in
            guard active, motion.moving else { return }
            motion.snap(center: scene.center, stacked: stacked)
            scene.settle()
            videoKey = scene.currentKey
        }
        .onDisappear { motion.cancel(); setBusy(false) }
    }

    private func card(_ item: CarouselScene.Item, metrics: CardMetrics) -> some View {
        let distance = CGFloat(item.ordinal) - motion.focus
        let isCurrent = item.id == scene.currentKey
        let song = isCurrent && currentSong.id == item.entry.song.id ? currentSong : item.entry.song
        return CarouselCard(song: song, isCurrent: isCurrent, isPlaying: isCurrent && isPlaying,
                            rendersMotion: item.id == videoKey, motionSuspended: motion.moving,
                            reportsArtworkFrame: isCurrent && !motion.moving,
                            videoSession: videoSession, distance: distance, metrics: metrics)
            .modifier(PlayerNeighbourFade(isCurrent: isCurrent))
            .transition(.opacity)
            .onTapGesture {
                guard !isCurrent, !stacked else { return }
                commitSwipe(item.ordinal > scene.center ? 1 : -1)
            }
            .allowsHitTesting(isCurrent || (!stacked && abs(distance) < 1.5))
    }

    private func swipe(page: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if horizontal == nil { horizontal = abs(value.translation.width) > abs(value.translation.height) }
                guard horizontal == true else { onPull(value.translation.height); return }
                if !motion.moving { videoSession.pause() }
                motion.drag(translation: value.translation.width, page: page, center: scene.center,
                            canPrevious: selection.canMove(-1), canNext: selection.canMove(1))
            }
            .onEnded { value in
                defer { horizontal = nil; motion.endGesture() }
                guard horizontal == true else { onPullEnd(value.translation.height, value.predictedEndTranslation.height); return }
                let wanted = CarouselSwipeIntent.direction(translation: value.translation.width,
                                                           predicted: value.predictedEndTranslation.width, page: page)
                if selection.canMove(wanted) { commitSwipe(wanted) }
                else { settle() }
            }
    }

    private func selectionChanged(_ next: CarouselSelection, preferredDirection: Int? = nil) {
        guard next != scene.selection else { return }
        let previousID = scene.selection.current?.id
        let adjacent = scene.select(next, preferredDirection: preferredDirection)
        if previousID == next.current?.id && motion.moving { return }
        if previousID != next.current?.id, adjacent {
            videoSession.pause()
            settle()
        } else {
            motion.snap(center: scene.center, stacked: stacked)
            scene.settle()
            videoKey = scene.currentKey
        }
    }

    /// Commit the real queue immediately so card title, index, duration and audio stay together.
    /// Transport defers non-audio side effects while the compositor settles the strip.
    private func commitSwipe(_ direction: Int) {
        guard !playerInMotion, selection.canMove(direction) else { settle(); return }
        motion.hold()
        setBusy(true)
        videoSession.pause()
        let before = scene.selection.current?.id
        let result = skip(direction)
        selectionChanged(result, preferredDirection: direction)
        if result.current?.id == before { settle() }
    }

    private func settle() {
        motion.settle(center: scene.center, stacked: stacked, reduceMotion: reduceMotion) {
            scene.settle()
            videoKey = scene.currentKey
        }
    }

}

/// The card's size in the room it is given (Android's CarouselCard): the artwork as large as the
/// width (80 % of it, so the neighbours peek in) and the height allow, and the album line only when
/// there is height for it.
struct CardMetrics {
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
/// the cards slide and scale but never turn. [stack] (0…1) blends towards the stacked layout: one
/// place over, a card sits centred behind the current one, unturned and a little larger.
struct DepthCard: GeometryEffect {
    var distance: CGFloat
    let width: CGFloat
    var stack: CGFloat
    let hideLeft: Bool
    let reduceMotion: Bool
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(distance, stack) }
        set { distance = newValue.first; stack = newValue.second }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let pose = CarouselPose(distance: distance, width: width, stack: stack, hideLeft: hideLeft, reduceMotion: reduceMotion)
        var rotation = CATransform3DIdentity
        rotation.m34 = -0.45 / max(width, 1)
        rotation = CATransform3DRotate(rotation, CGFloat(pose.turn * .pi / 180), 0, 1, 0)
        return ProjectionTransform(CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
            .concatenating(ProjectionTransform(rotation))
            .concatenating(ProjectionTransform(CGAffineTransform(scaleX: pose.scale, y: pose.scale)))
            .concatenating(ProjectionTransform(CGAffineTransform(translationX: size.width / 2 + pose.x, y: size.height / 2 + pose.y)))
    }
}

/// One card: the artwork with the title, artist and (room allowing) album beneath, as one rounded
/// card in its own artwork's colours. The current card carries the favourite button; neighbours
/// darken with their distance.
private struct CarouselCard: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    let rendersMotion: Bool
    let motionSuspended: Bool
    let reportsArtworkFrame: Bool
    let videoSession: MotionVideoSession
    let distance: CGFloat
    let metrics: CardMetrics
    @Environment(LibraryActions.self) private var actions
    @Environment(\.playerArtworkInFlight) private var artworkInFlight
    @Environment(\.palette) private var palette
    @State private var artworkPalette = ArtworkPaletteState()
    @State private var artworkRevision = 0

    var body: some View {
        let colors = LyricsColors(artworkPalette.palette(for: song.url))
        let shape = RoundedRectangle(cornerRadius: Radius.large + CardMetrics.padding, style: .continuous)
        VStack(spacing: 0) {
            Color.clear
                .frame(width: metrics.artSide, height: metrics.artSide)
                .background { if reportsArtworkFrame { Color.clear.playerArtworkFrame(expanded: true) } }
                .overlay {
                    MotionCoverView(song: song, playing: isCurrent && isPlaying, rendersVideo: rendersMotion && !artworkInFlight, maxPixels: isCurrent ? 1200 : 600, animateStill: false,
                                    suspended: motionSuspended, videoSession: videoSession)
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
            .padding(.leading, Spacing.xs)
            .padding(.top, Spacing.sm)
            .frame(width: metrics.artSide, height: metrics.metadataHeight, alignment: .top)
        }
        .padding(CardMetrics.padding)
        .background(CardSurface(colors: colors, shape: shape).modifier(PlayerChromeFade()))
        .overlay(shape.fill(.black.opacity(Double(min(abs(distance), 1)) * 0.45)).allowsHitTesting(false))
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
        content.opacity(isCurrent ? 1 : (drag.isMoving ? 0 : 1))
            .animation(.easeOut(duration: 0.12), value: drag.isMoving)
    }
}
