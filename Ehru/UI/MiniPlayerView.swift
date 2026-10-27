import SwiftUI

struct MiniPlayerView: View {
    @Environment(PlayerController.self) private var player
    let onOpen: () -> Void

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                ArtworkView(song: song, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .lineLimit(1)
                    Text(song.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 32, height: 32)
                }
            }
            .font(.title3)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}
