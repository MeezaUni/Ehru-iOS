import SwiftUI

struct SongRow: View {
    let song: Song
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(song.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(song.duration.formattedDuration)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
