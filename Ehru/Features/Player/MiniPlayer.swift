import SwiftUI

/// The bar above the navigation while something is loaded: artwork, title, artist, previous,
/// play / pause, next, and a thin progress line. Tapping it opens Now Playing.
struct MiniPlayer: View {
    let song: Song
    let onOpen: () -> Void
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette

    var body: some View {
        let state = player.state
        HStack(spacing: Spacing.md) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.md) {
                    SongArtworkView(song: song, maxPixels: 132)
                        .frame(width: ArtworkSize.miniPlayer, height: ArtworkSize.miniPlayer)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
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
            Button { player.skipPrevious() } label: { Image(systemName: "backward.fill").frame(width: 36, height: 44) }
                .accessibilityLabel("Previous track")
            Button { player.togglePlayPause() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 40, height: 44)
            }
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Button { player.skipNext() } label: { Image(systemName: "forward.fill").frame(width: 36, height: 44) }
                .accessibilityLabel("Next track")
        }
        .foregroundStyle(palette.onSurface)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs + 2)
        .overlay(alignment: .bottom) {
            ProgressLine(durationMs: state.durationMs)
                .frame(height: 3)
                .padding(.horizontal, Spacing.md)
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
