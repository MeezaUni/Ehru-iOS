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
    /// The playing song as the player has it now (its favourite state may be newer than the entry's).
    let currentSong: Song
    let isPlaying: Bool
    /// +1 next, -1 previous: always a change of song, never a restart.
    let skip: (Int) -> Void
    /// A downward drag on the cards pulls the player down: the distance while dragging, then the
    /// distance and the predicted end on release.
    var onPull: (CGFloat) -> Void = { _ in }
    var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the strip is, in points from the current card at rest.
    @State private var position: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var horizontal: Bool?
    @State private var shown = Neighbours()

    private struct Neighbours {
        var current: UUID?
        var previous: UUID?
        var next: UUID?
    }

    /// Dragged past this share of a page, the song changes on release.
    private static let skipFraction: CGFloat = 0.25
    /// A release faster than this (points per second, roughly) skips whatever the distance.
    private static let flingSpeed: CGFloat = 450
    /// Dragging towards a side with no song moves the strip this much per point.
    private static let edgeResistance: CGFloat = 0.25
    private static let settle = Animation.spring(response: 0.42, dampingFraction: 0.88)

    var body: some View {
        GeometryReader { geometry in
            let metrics = CardMetrics(geometry.size)
            let page = metrics.cardWidth * DepthCard.sideSpacing
            ZStack {
                ForEach(pages, id: \.key) { item in
                    let distance = CGFloat(item.slot) + (page > 0 ? position / page : 0)
                    CarouselCard(song: item.slot == 0 ? currentSong : item.entry.song, isCurrent: item.slot == 0,
                                 isPlaying: item.slot == 0 && isPlaying, distance: distance, metrics: metrics)
                        .modifier(DepthCard(distance: distance, width: metrics.cardWidth, stack: stacked ? 1 : 0,
                                            hideLeft: next != nil, reduceMotion: reduceMotion))
                        .zIndex(abs(distance) < 0.5 ? 1 : 0)
                        .onTapGesture {
                            if item.slot != 0, !stacked { skip(item.slot) }
                        }
                        .allowsHitTesting(item.slot == 0 || !stacked)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(swipe(page: page))
            .onChange(of: current?.id) { _, id in trackChanged(to: id, page: page) }
        }
        .onAppear { shown = Neighbours(current: current?.id, previous: previous?.id, next: next?.id) }
        .onChange(of: previous?.id) { _, id in shown.previous = id }
        .onChange(of: next?.id) { _, id in shown.next = id }
    }

    private struct Page {
        let key: String
        let slot: Int
        let entry: QueueEntry
    }

    /// Previous, current and next, keyed by queue entry so a card keeps its loaded artwork as it
    /// becomes the current one (a 2-song repeat can make one entry both neighbours).
    private var pages: [Page] {
        guard let current else { return [] }
        var result: [Page] = []
        if let previous { result.append(Page(key: previous.id == current.id ? "\(previous.id)#-1" : previous.id.uuidString, slot: -1, entry: previous)) }
        result.append(Page(key: current.id.uuidString, slot: 0, entry: current))
        if let next {
            let duplicate = next.id == current.id || next.id == previous?.id
            result.append(Page(key: duplicate ? "\(next.id)#1" : next.id.uuidString, slot: 1, entry: next))
        }
        return result
    }

    private func swipe(page: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if horizontal == nil { horizontal = abs(value.translation.width) > abs(value.translation.height) }
                guard horizontal == true else {
                    onPull(value.translation.height)
                    return
                }
                if dragStart == nil { dragStart = position }
                let target = (dragStart ?? 0) + value.translation.width
                let towardsMissing = (target < 0 && next == nil) || (target > 0 && previous == nil)
                position = towardsMissing ? target * Self.edgeResistance : target
            }
            .onEnded { value in
                defer {
                    horizontal = nil
                    dragStart = nil
                }
                guard horizontal == true else {
                    onPullEnd(value.translation.height, value.predictedEndTranslation.height)
                    return
                }
                let speed = value.predictedEndTranslation.width - value.translation.width
                let wanted: Int = if abs(speed) > Self.flingSpeed {
                    speed < 0 ? 1 : -1
                } else if abs(position) > page * Self.skipFraction {
                    position < 0 ? 1 : -1
                } else {
                    0
                }
                let allowed = (wanted == 1 && next != nil) || (wanted == -1 && previous != nil)
                if allowed {
                    skip(wanted)
                } else {
                    withAnimation(Self.settle) { position = 0 }
                }
            }
    }

    /// The new song's card is where its page stood (one page over, or wherever the finger left it):
    /// the strip shifts by a page without moving a pixel, then settles on the new current card.
    private func trackChanged(to id: UUID?, page: CGFloat) {
        let direction: CGFloat = id == nil ? 0 : id == shown.next ? 1 : id == shown.previous ? -1 : 0
        shown = Neighbours(current: id, previous: previous?.id, next: next?.id)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { position += direction * page }
        DispatchQueue.main.async {
            withAnimation(Self.settle) { position = 0 }
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
struct DepthCard: ViewModifier {
    let distance: CGFloat
    let width: CGFloat
    let stack: CGFloat
    let hideLeft: Bool
    let reduceMotion: Bool

    static let sideSpacing: CGFloat = 0.62
    private static let sideScale: CGFloat = 0.78
    private static let reducedSideScale: CGFloat = 0.86
    private static let turnDegrees: Double = 32
    private static let stackedBehindScale: CGFloat = 1.06
    private static let stackedHideRate: CGFloat = 1.5
    private static let vanishDistance: CGFloat = 1.6

    func body(content: Content) -> some View {
        let away = abs(distance)
        let near = min(away, 1)
        let side: CGFloat = distance < 0 ? -1 : distance > 0 ? 1 : 0
        let sideScale = reduceMotion ? Self.reducedSideScale : Self.sideScale
        // Out to the side half way, back behind the centre at one place over.
        let stackedOut = 2 * min(near, 1 - near)
        let scale = lerp(1 - (1 - sideScale) * near, 1 + (Self.stackedBehindScale - 1) * near, stack)
        let x = lerp(distance * width * Self.sideSpacing, side * width * Self.sideSpacing * stackedOut, stack)
        let turn = reduceMotion ? 0 : -Double(side) * Self.turnDegrees * Double(near) * Double(1 - stack)
        let vanish = min(max(1 - max(away - 1, 0) / (Self.vanishDistance - 1), 0), 1)
        let gathered = hideLeft ? min(stack * min(max(-distance, 0), 1) * Self.stackedHideRate, 1) : 0
        content
            .rotation3DEffect(.degrees(turn), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .scaleEffect(scale)
            .offset(x: x)
            .opacity(Double(vanish * (1 - gathered)))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

/// One card: the artwork with the title, artist and (room allowing) album beneath, as one rounded
/// card in its own artwork's colours. The current card carries the favourite button; neighbours
/// darken with their distance.
private struct CarouselCard: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    let distance: CGFloat
    let metrics: CardMetrics
    @Environment(LibraryActions.self) private var actions
    @Environment(\.palette) private var palette
    @State private var artworkPalette = ArtworkPaletteState()
    @State private var artworkRevision = 0

    var body: some View {
        let colors = LyricsColors(artworkPalette.palette(for: song.url))
        let shape = RoundedRectangle(cornerRadius: Radius.large + CardMetrics.padding, style: .continuous)
        VStack(spacing: 0) {
            MotionCoverView(song: song, playing: isCurrent && isPlaying, animateStill: true)
                .frame(width: metrics.artSide, height: metrics.artSide)
                .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
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
            .padding(.leading, Spacing.xs)
            .padding(.top, Spacing.sm)
            .frame(width: metrics.artSide, height: metrics.metadataHeight, alignment: .top)
        }
        .padding(CardMetrics.padding)
        .background(CardSurface(colors: colors, shape: shape))
        .overlay(Color.black.opacity(Double(min(abs(distance), 1)) * 0.45).allowsHitTesting(false))
        .clipShape(shape)
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
