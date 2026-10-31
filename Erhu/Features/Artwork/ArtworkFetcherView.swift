import PhotosUI
import SwiftUI

/// The Artwork Fetcher tool: albums without a cover and artists without a photo, each opening a
/// picker of what was found online (or a photo from the library).
struct ArtworkFetcherView: View {
    @Environment(ArtworkFetcherStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var tab = 0
    @State private var target: ArtworkTarget?

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $tab) {
                    Text("Albums (\(store.albums.count))").tag(0)
                    Text("Artists (\(store.artists.count))").tag(1)
                }
                .pickerStyle(.segmented)
                if store.isScanning {
                    HStack { ProgressView(); Text("Looking for missing artwork…") }
                }
                if let message = store.message {
                    Text(message).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
                }
            } footer: {
                Text(tab == 0
                    ? "Albums whose songs carry no cover. A cover you pick is saved into every song of the album."
                    : "Artist photos are matched automatically when music is added. Retry missing photos here, or choose an artist to replace their image.")
            }
            if tab == 0 {
                Section {
                    if store.albums.isEmpty && !store.isScanning {
                        Text("Every album has a cover.").foregroundStyle(palette.onSurfaceVariant)
                    }
                    ForEach(store.albums) { album in
                        Button { target = .album(album) } label: {
                            TargetRow(title: album.title, subtitle: album.artist, status: store.albumStatus[album.id]) {
                                AlbumArtworkView(albumId: album.id, maxPixels: 120)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Section {
                    Button {
                        Task { await store.autoMatchArtists() }
                    } label: {
                        HStack {
                            Label("Match photos automatically", systemImage: "sparkles")
                            if store.isAutoMatching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(store.isAutoMatching || !store.artists.contains(where: { library.artist($0.id)?.artworkPath == nil }))
                    ForEach(store.artists) { artist in
                        Button { target = .artist(artist) } label: {
                            TargetRow(title: artist.name, subtitle: countLabel(artist.songCount, "song"), status: store.artistStatus[artist.id]) {
                                ArtistArtworkView(artist: artist, fontSize: 18)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Artwork Fetcher")
        .toolbar {
            Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Find missing artwork")
                .disabled(store.isScanning)
        }
        .task { if store.albums.isEmpty && store.artists.isEmpty { await store.scan() } }
        .sheet(item: $target) { ArtworkPickerSheet(target: $0) }
    }
}

private struct TargetRow<Art: View>: View {
    let title: String
    let subtitle: String
    let status: ArtworkStatus?
    @ViewBuilder let art: () -> Art
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.md) {
            art().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                if let status { Text(status.label).font(.caption2).foregroundStyle(palette.onSurfaceVariant).lineLimit(2) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.onSurfaceVariant)
        }
        .contentShape(Rectangle())
    }
}

/// What artwork is being chosen for.
enum ArtworkTarget: Identifiable {
    case album(Album)
    case artist(Artist)

    var id: String {
        switch self {
        case .album(let album): "album:\(album.id)"
        case .artist(let artist): "artist:\(artist.id)"
        }
    }

    var name: String {
        switch self {
        case .album(let album): album.title
        case .artist(let artist): artist.name
        }
    }
}

/// Covers or photos found online in a grid, and a photo from the library; tap one to save it.
struct ArtworkPickerSheet: View {
    let target: ArtworkTarget
    @Environment(ArtworkFetcherStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ArtworkCandidate] = []
    @State private var loading = true
    @State private var saving = false
    @State private var photo: PhotosPickerItem?
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    if loading {
                        HStack { ProgressView(); Text("Searching iTunes, MusicBrainz, Deezer and Wikimedia…") }.font(.footnote)
                    } else if candidates.isEmpty {
                        Text("Nothing found online.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.sm)], spacing: Spacing.sm) {
                        ForEach(candidates) { candidate in
                            Button { Task { await apply(candidate) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    AsyncImage(url: URL(string: candidate.url)) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else if phase.error != nil {
                                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                                        } else {
                                            ProgressView()
                                        }
                                    }
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                                    Text(candidate.source).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use this image from \(candidate.source)")
                        }
                    }
                }
                .padding(Spacing.lg)
            }
            .disabled(saving)
            .overlay { if saving { ProgressView("Saving…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Couldn’t save artwork", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            saveError = "The selected photo could not be loaded."
                            return
                        }
                        await apply(data)
                    } catch { saveError = error.localizedDescription }
                    photo = nil
                }
            }
        }
    }

    private func load() async {
        switch target {
        case .album(let album): candidates = await store.albumCovers(album)
        case .artist(let artist): candidates = await store.artistPhotos(artist)
        }
        loading = false
    }

    private var failureReason: String {
        let status: ArtworkStatus?
        switch target {
        case .album(let album): status = store.albumStatus[album.id]
        case .artist(let artist): status = store.artistStatus[artist.id]
        }
        if case .failed(let reason)? = status { return reason }
        return "The image could not be saved. Try another image."
    }

    private func apply(_ candidate: ArtworkCandidate) async {
        guard !saving else { return }
        saving = true
        let saved: Bool
        switch target {
        case .album(let album): saved = await store.applyCover(candidate, to: album)
        case .artist(let artist): saved = await store.applyPhoto(candidate, to: artist)
        }
        saving = false
        if saved { dismiss() } else { saveError = failureReason }
    }

    private func apply(_ image: Data) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        switch target {
        case .album(let album):
            if await store.applyCover(image, to: album) { dismiss() } else { saveError = failureReason }
        case .artist(let artist):
            do {
                try store.storePhoto(image, for: artist, source: "CUSTOM")
                dismiss()
            } catch { saveError = error.localizedDescription }
        }
    }
}
