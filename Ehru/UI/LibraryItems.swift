import SwiftUI

/// What can be done with a song from any list (Android's SongActions).
struct SongActions {
    var toggleFavorite: (Song) -> Void
    var playNext: (Song) -> Void
    var addToQueue: (Song) -> Void
    var startRadio: (Song) -> Void
    var addToPlaylist: (Song) -> Void
    var viewDetails: ((Song) -> Void)?
    var editTags: ((Song) -> Void)?
    var fixTags: ((Song) -> Void)?
    /// Smart playlist pages only: hide the song from (or return it to) the smart mixes.
    var hideFromMixes: ((Song) -> Void)?
    /// Playlist pages only.
    var removeFromPlaylist: ((Song) -> Void)?
    var like: ((Song) -> Void)?
}

/// The song actions as menu items (a row's "…" button and its long-press menu).
struct SongActionItems: View {
    let song: Song
    let actions: SongActions

    var body: some View {
        Button { actions.playNext(song) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { actions.addToQueue(song) } label: { Label("Add to queue", systemImage: "text.badge.plus") }
        Button { actions.startRadio(song) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
        Button { actions.addToPlaylist(song) } label: { Label("Add to playlist", systemImage: "music.note.list") }
        Button { actions.toggleFavorite(song) } label: {
            Label(song.isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: song.isFavorite ? "heart.slash" : "heart")
        }
        if let view = actions.viewDetails {
            Button { view(song) } label: { Label("View metadata", systemImage: "info.circle") }
        }
        if let edit = actions.editTags {
            Button { edit(song) } label: { Label("Edit tags", systemImage: "pencil") }
        }
        if let fix = actions.fixTags {
            Button { fix(song) } label: { Label("Fix tags online", systemImage: "wand.and.stars") }
        }
        if let remove = actions.removeFromPlaylist {
            Button(role: .destructive) { remove(song) } label: { Label("Remove from playlist", systemImage: "minus.circle") }
        }
        if let hide = actions.hideFromMixes {
            Button(role: .destructive) { hide(song) } label: { Label("Hide from Smart Playlists", systemImage: "eye.slash") }
        }
    }
}

/// A track in a list: artwork (or track number), title (highlighted when playing), "artist · album",
/// a heart and the actions menu.
struct TrackRow: View {
    let song: Song
    let isCurrent: Bool
    var showTrackNumber = false
    var subtitle: String?
    let actions: SongActions
    let onTap: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var swipe: CGFloat = 0
    @GestureState private var gestureActive = false
    @State private var horizontal: Bool?

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button(action: onTap) {
                HStack(spacing: Spacing.md) {
                    leading
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isCurrent ? Color.accentColor : palette.onSurface)
                            .lineLimit(1)
                        Text(subtitle ?? [song.artist, song.album].filter { !$0.isBlank }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { actions.toggleFavorite(song) } label: {
                Image(systemName: song.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(song.isFavorite ? palette.primary : palette.onSurfaceVariant)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(song.isFavorite ? "Remove from favorites" : "Add to favorites")
            Menu {
                SongActionItems(song: song, actions: actions)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(palette.onSurfaceVariant)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.xs)
        .offset(x: swipe)
        .background(alignment: swipe >= 0 ? .leading : .trailing) {
            if swipe != 0 {
                Label(swipe > 0 ? "Queue" : "Like", systemImage: swipe > 0 ? "text.badge.plus" : "heart.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.primary)
                    .padding(.horizontal, Spacing.xl)
                    .frame(maxHeight: .infinity)
                    .background(palette.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .opacity(min(Double(abs(swipe) / 60), 1))
                    .frame(width: abs(swipe), alignment: swipe > 0 ? .leading : .trailing)
                    .clipped()
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($gestureActive) { _, active, _ in active = true }
            .updating($swipe) { value, offset, transaction in
                guard horizontal ?? HorizontalGestureIntent.accepts(value.translation) else { return }
                transaction.disablesAnimations = true
                offset = value.translation.width.clamped(-112, 112)
            }
            .onChanged { value in
                if horizontal == nil { horizontal = HorizontalGestureIntent.accepts(value.translation) }
            }
            .onEnded { value in
                defer { horizontal = nil }
                switch SongSwipeAction.committed(translation: value.translation, startedHorizontally: horizontal == true) {
                case .queue: actions.addToQueue(song)
                case .like:
                    if let like = actions.like { like(song) }
                    else if !song.isFavorite { actions.toggleFavorite(song) }
                case nil: break
                }
            })
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: swipe == 0)
        .onChange(of: gestureActive) { _, active in if !active { horizontal = nil } }
        .accessibilityAction(named: "Add to queue") { actions.addToQueue(song) }
        .accessibilityAction(named: "Like song") {
            if let like = actions.like { like(song) }
            else if !song.isFavorite { actions.toggleFavorite(song) }
        }
        .contextMenu { SongActionItems(song: song, actions: actions) }
    }

    @ViewBuilder private var leading: some View {
        if showTrackNumber && song.trackNumber > 0 {
            Text("\(song.trackNumber)")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : palette.onSurfaceVariant)
                .frame(width: ArtworkSize.list, height: ArtworkSize.list)
        } else {
            SongArtworkView(song: song, maxPixels: 144)
                .frame(width: ArtworkSize.list, height: ArtworkSize.list)
                .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
    }
}

/// An artwork-first card: square cover, title, one quiet line.
struct ArtworkTile<Cover: View>: View {
    let title: String
    let subtitle: String?
    var circular = false
    let action: () -> Void
    @ViewBuilder let cover: () -> Cover
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: circular ? .center : .leading, spacing: 2) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { cover() }
                    .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)))
                    .padding(.bottom, Spacing.sm - 2)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                }
            }
        }
        .pressable()
    }
}

struct AlbumTile: View {
    let album: Album
    let action: () -> Void

    var body: some View {
        ArtworkTile(title: album.title, subtitle: album.artist, action: action) { AlbumArtworkView(albumId: album.id) }
    }
}

struct PlaylistTile: View {
    let playlist: Playlist
    let action: () -> Void

    var body: some View {
        ArtworkTile(title: playlist.name, subtitle: countLabel(playlist.songCount, "song"), action: action) { PlaylistCoverView(playlist: playlist) }
    }
}

struct ArtistTile: View {
    let artist: Artist
    let action: () -> Void

    var body: some View {
        ArtworkTile(title: artist.name, subtitle: "\(countLabel(artist.songCount, "song")) · \(countLabel(artist.albumCount, "album"))",
                    circular: true, action: action) { ArtistArtworkView(artist: artist) }
    }
}

struct SongTile: View {
    let song: Song
    let action: () -> Void

    var body: some View {
        ArtworkTile(title: song.title, subtitle: song.artist, action: action) { SongArtworkView(song: song) }
    }
}

/// First cell of the playlist grid: same footprint as a playlist card.
struct NewPlaylistTile: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        ArtworkTile(title: "New playlist", subtitle: nil, action: action) {
            ZStack {
                Rectangle().fill(palette.surfaceVariant)
                Image(systemName: "plus").font(.system(size: 32, weight: .semibold)).foregroundStyle(palette.primary)
            }
        }
    }
}

struct SectionHeading: View {
    let title: String
    var onMore: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(palette.onSurface).lineLimit(1)
            Spacer()
            if let onMore {
                Button(action: onMore) {
                    HStack(spacing: Spacing.xs) {
                        Text("More")
                        Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                }
                .accessibilityLabel("More \(title)")
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.sm)
    }
}

/// A titled horizontal row of cards.
struct Shelf<Content: View>: View {
    let title: String
    var onMore: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: title, onMore: onMore)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Spacing.md) { content() }
                    .padding(.horizontal, Spacing.gutter)
            }
        }
    }
}

struct EmptyState: View {
    let message: String
    var systemImage = "music.note"
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(palette.onSurfaceVariant)
            Text(message).font(.body).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xxl)
    }
}

/// A short message that slides up above the bottom chrome and fades away.
struct Toast: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.onPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(Capsule().fill(palette.primary))
            .padding(.horizontal, Spacing.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
