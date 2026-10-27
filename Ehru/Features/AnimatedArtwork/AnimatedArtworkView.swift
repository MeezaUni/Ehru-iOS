import SwiftUI

struct AnimatedArtworkView: View {
    @Environment(AnimatedArtworkStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    private var albums: [Album] {
        library.albums.filter { query.isBlank || SearchNormalizer.matches($0.title + " " + $0.artist, query) }
    }

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Toggle("Play downloaded motion covers", isOn: $store.enabled)
                Text("Download an album’s Apple motion cover to use it offline in Now Playing and on the album page. Covers stay muted and pause in the background, in Low Power Mode, and with Reduce Motion enabled.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.downloading != nil {
                Section { Button("Cancel download", role: .cancel) { store.cancel() } }
            }
            Section("Albums") {
                if albums.isEmpty { Text("No matching albums in your library.").foregroundStyle(.secondary) }
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack(spacing: Spacing.md) {
                            AlbumArtworkView(albumId: album.id, maxPixels: 120)
                                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(album.title).font(.headline)
                                Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if let status = store.status[album.id] { Text(status.label).font(.caption).foregroundStyle(.secondary) }
                        else if store.saved.covers[String(album.id)] != nil { Text("Downloaded · available offline").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button(store.saved.covers[String(album.id)] == nil ? "Find & download" : "Download again") { store.download(album) }
                                .disabled(store.downloading != nil)
                            if store.saved.covers[String(album.id)] != nil {
                                Spacer()
                                Button("Remove", role: .destructive) { store.remove(album) }.disabled(store.downloading == album.id)
                            }
                        }.buttonStyle(.bordered)
                    }.padding(.vertical, Spacing.xs)
                }
            }
        }
        .searchable(text: $query, prompt: "Album or artist")
        .navigationTitle("Animated covers")
    }
}
