import SwiftUI

struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @State private var position: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            if let song = player.currentSong {
                ArtworkView(song: song, size: 280)
                    .shadow(radius: 16, y: 8)
                VStack(spacing: 4) {
                    Text(song.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(song.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                progress
                controls
                modes
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDragIndicator(.visible)
        .onChange(of: player.currentTime, initial: true) { _, time in
            if !isScrubbing { position = time }
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(value: $position, in: 0...max(player.duration, 1), onEditingChanged: { editing in
                isScrubbing = editing
                if !editing { player.seek(to: position) }
            })
            HStack {
                Text(position.formattedDuration)
                Spacer()
                Text("-" + max(player.duration - position, 0).formattedDuration)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
            }
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
        }
        .font(.title)
        .buttonStyle(.plain)
    }

    private var modes: some View {
        HStack {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? Color.accentColor : Color.secondary)
            }
            Spacer()
            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 32)
    }
}
