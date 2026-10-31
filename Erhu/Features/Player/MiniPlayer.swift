import SwiftUI

/// The bar above the navigation while something is loaded: artwork, title, artist, previous,
/// play / pause, next, and a thin progress line. Tapping it opens Now Playing.
struct MiniPlayer: View {
    let song: Song
    var compactness: CGFloat = 0
    let onOpen: () -> Void
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette

    var body: some View {
        let state = player.state
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.md) {
                    MiniPlayerArtwork(song: song)
                        .frame(width: ArtworkSize.miniPlayer, height: ArtworkSize.miniPlayer)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        .playerArtworkFrame(expanded: false)
                        .modifier(MiniArtworkVisibility())
                        .accessibilityLabel("Album artwork")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface).lineLimit(1)
                        Text(song.artist).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")
            Button { player.skipPrevious() } label: { Image(systemName: "backward.fill").frame(width: 44, height: 48).contentShape(Rectangle()) }
                .frame(width: 44 * (1 - compactness)).clipped()
                .opacity(Double(CGFloat(1) - compactness))
                .allowsHitTesting(compactness < 0.5)
                .accessibilityHidden(compactness >= 0.5)
                .accessibilityLabel("Previous track")
            Button { player.togglePlayPause() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 44, height: 48).contentShape(Rectangle())
            }
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Button { player.skipNext() } label: { Image(systemName: "forward.fill").frame(width: 44, height: 48).contentShape(Rectangle()) }
                .frame(width: 44 * (1 - compactness)).clipped()
                .opacity(Double(CGFloat(1) - compactness))
                .allowsHitTesting(compactness < 0.5)
                .accessibilityHidden(compactness >= 0.5)
                .accessibilityLabel("Next track")
        }
        .foregroundStyle(palette.onSurface)
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs + 2)
        // The whole bar takes touches, so nothing behind it can be pressed through its gaps.
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            ProgressLine(durationMs: state.durationMs)
                .frame(height: 3)
                .padding(.horizontal, Spacing.md)
        }
    }
}

/// Media preparation is structural, not driven by the playhead. The mini, flight and carousel
/// pass ownership of one native layer instead of replacing it with a first-frame photograph.
private struct MiniPlayerArtwork: View {
    let song: Song
    @Environment(PlayerController.self) private var player
    @Environment(AnimatedArtworkStore.self) private var artwork
    @Environment(PlayerDragState.self) private var drag
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualWorkBudget) private var budget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Request: Equatable {
        let url: URL?
        let entryID: UUID?
        let ownsLayer: Bool
        let mayAnimate: Bool
        let active: Bool
    }

    var body: some View {
        let ownsLayer = !drag.isPresented || !drag.isReady
        let url = artwork.url(for: song)
        let request = Request(url: url, entryID: player.state.currentEntry?.id, ownsLayer: ownsLayer,
                              mayAnimate: !reduceMotion && budget.allowsDecorativeMotion, active: scenePhase == .active)
        let session = player.coverVideos.currentSession
        MotionCoverView(song: song, videoURL: url, playing: true,
                        rendersVideo: ownsLayer && player.coverVideos.currentURL == url,
                        maxPixels: 132, suspended: drag.isPresented && drag.isMoving,
                        videoSession: session, tracksScrollVisibility: false)
            .onChange(of: request, initial: true) { _, next in
                guard next.ownsLayer else { return }
                guard next.mayAnimate, let url = next.url, let id = next.entryID else {
                    player.coverVideos.stop()
                    return
                }
                guard next.active else { return }
                player.coverVideos.prepareMini(url: url, entryID: id)
            }
    }
}

/// The mini player's progress, on its own so only it redraws as the song plays.
private struct ProgressLine: View {
    let durationMs: Int64
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette

    var body: some View {
        let progress = durationMs > 0 ? min(Double(player.clock.positionMs) / Double(durationMs), 1) : 0
        GeometryReader { geometry in
            Capsule().fill(palette.primary).frame(width: geometry.size.width * progress, height: 3)
        }
    }
}
