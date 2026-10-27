import SwiftUI
import UIKit

struct ArtworkView: View {
    let song: Song
    let size: CGFloat
    @State private var image: UIImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.08)
    }

    var body: some View {
        ZStack {
            shape.fill(Color.secondary.opacity(0.2))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: song.id) {
            image = nil
            if let data = await SongMetadata.artworkData(for: song.url) {
                image = UIImage(data: data)
            }
        }
    }
}
