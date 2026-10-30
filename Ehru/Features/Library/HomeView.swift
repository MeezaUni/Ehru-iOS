import SwiftUI

/// The Home destination: the Smart Playlists as a hero banner (whenever the library has songs),
/// Featured Albums, Recently Played albums and playlists, then every track. The shelves scroll
/// away with the tracks; each shelf scrolls sideways on its own.
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MixStore.self) private var mixes
    @Environment(PlayerController.self) private var player
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router

    var body: some View {
        let songs = library.songs
        let smart = mixes.mixes
        let hasSongs = !songs.isEmpty
        let showsHero = hasSongs && (!(smart?.mixes.isEmpty ?? true) || smart?.needsMoreListening == true)
        let hasShelves = hasSongs || !library.recentAlbums.isEmpty || !library.recentPlaylists.isEmpty
        let songActions = router.songActions(actions)
        let currentId = player.state.currentSong?.id
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if showsHero, let smart {
                    SmartMixHero(mixes: smart.mixes, needsMoreListening: smart.needsMoreListening,
                                 isActive: router.section == .home && (router.paths[.home]?.isEmpty ?? true) &&
                                     !router.showsNowPlaying && !router.showsSearch && !router.showsDrawer,
                                 onOpen: { router.open(.smartPlaylist($0)) }, onPlay: { actions.playMix($0) })
                        .padding(.top, Spacing.xs)
                        .padding(.bottom, Spacing.lg)
                }
                shelves(showsRecentNote: hasSongs)
                if hasShelves { SectionHeading(title: "Tracks") }
                if songs.isEmpty {
                    EmptyState(message: library.isScanning ? "Scanning your music…" : "No songs yet. Add music with the Files app, Wi-Fi Transfer or the + button.",
                               systemImage: "house")
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        TrackRow(song: song, isCurrent: song.id == currentId, actions: songActions) {
                            actions.play(songs, startIndex: index)
                        }
                    }
                }
            }
            .padding(.bottom, Spacing.lg)
        }
        .tracksLibraryScrolling()
        .refreshable { library.scan() }
        .onAppear { if router.section == .home { mixes.start() } }
        .onChange(of: router.section) { _, section in if section == .home { mixes.start() } }
    }

    @ViewBuilder
    private func shelves(showsRecentNote: Bool) -> some View {
        if !library.featuredAlbums.isEmpty {
            Shelf(title: "Featured Albums") {
                ForEach(library.featuredAlbums) { album in
                    AlbumTile(album: album) { router.open(.album(album.id)) }.frame(width: ArtworkSize.shelf)
                }
            }
            .padding(.bottom, Spacing.lg)
        }
        if !library.recentAlbums.isEmpty {
            Shelf(title: "Recently played albums") {
                ForEach(library.recentAlbums) { album in
                    AlbumTile(album: album) { router.open(.album(album.id)) }.frame(width: ArtworkSize.shelf)
                }
            }
            .padding(.bottom, Spacing.lg)
        } else if showsRecentNote {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Recently played albums")
                Text("Albums you play show up here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.gutter)
            }
            .padding(.bottom, Spacing.lg)
        }
        if !library.recentPlaylists.isEmpty {
            Shelf(title: "Recently played playlists") {
                ForEach(library.recentPlaylists) { playlist in
                    PlaylistTile(playlist: playlist) { router.open(.playlist(playlist.id)) }.frame(width: ArtworkSize.shelf)
                }
            }
            .padding(.bottom, Spacing.lg)
        }
    }
}

/// Which concepts lead the carousel: a fixed order for this app session (a new one each launch).
enum HomeSession {
    static let seed = Int64.random(in: .min ... .max)

    static func feature(_ mixes: [SmartMix], limit: Int, sessionSeed: Int64 = seed) -> [SmartMix] {
        Array(mixes.sorted { FeaturedAlbums.dailyRank(MixArt.seedOf($0.kind.key), sessionSeed) < FeaturedAlbums.dailyRank(MixArt.seedOf($1.kind.key), sessionSeed) }
            .prefix(limit))
    }
}

/// The Smart Playlists hero: one banner per mix, swiped sideways (and, while history is short,
/// a last page saying personal mixes come with listening). Tapping opens the mix; Play plays it.
struct SmartMixHero: View {
    let mixes: [SmartMix]
    let needsMoreListening: Bool
    var isActive = true
    let onOpen: (String) -> Void
    let onPlay: (String) -> Void
    @Environment(\.palette) private var palette
    @State private var page = 0
    @State private var visible = false
    @State private var interaction: UInt64 = 0
    @GestureState private var dragging = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Rotation: Hashable {
        let active: Bool
        let count: Int
        let page: Int
        let interaction: UInt64
    }

    private static let maxBanners = 6
    private static let aspect: CGFloat = 1.75

    @State private var width: CGFloat = 360

    var body: some View {
        let featured = HomeSession.feature(mixes, limit: Self.maxBanners)
        let count = featured.count + (needsMoreListening ? 1 : 0)
        let rotation = Rotation(active: isActive && visible && scenePhase == .active && !reduceMotion && !dragging,
                                count: count, page: page, interaction: interaction)
        let bannerWidth = max(width - Spacing.gutter * 2, 1)
        // Wide on every phone, never towering on a tablet or squashed on a small screen.
        let height = min(max(bannerWidth / Self.aspect, 168), 240)
        VStack(spacing: Spacing.sm) {
            if count > 0 {
                TabView(selection: $page) {
                    ForEach(0..<count, id: \.self) { index in
                        Group {
                            if index < featured.count {
                                MixBanner(mix: featured[index], aspect: Float(bannerWidth / height),
                                          onOpen: { interaction &+= 1; onOpen(featured[index].kind.key) },
                                          onPlay: { interaction &+= 1; onPlay(featured[index].kind.key) })
                            } else {
                                MoreListeningBanner()
                            }
                        }
                        .frame(width: bannerWidth, height: height)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: height)
                .simultaneousGesture(DragGesture(minimumDistance: 10)
                    .updating($dragging) { _, active, _ in active = true })
                if count > 1 { PageDots(count: count, current: page) }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .reportsScrollVisibility { visible = $0 }
        .onChange(of: count, initial: true) { _, count in page = min(page, max(count - 1, 0)) }
        .task(id: rotation) {
            guard rotation.active, rotation.count > 1 else { return }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.45)) { page = (rotation.page + 1) % rotation.count }
        }
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, new in width = new }
        })
    }
}

/// One mix as a banner: its art across the whole banner, the text and Play in its clear side.
private struct MixBanner: View {
    let mix: SmartMix
    let aspect: Float
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        let (art, look) = MixArtCache.banner(mix.kind, aspect: aspect)
        let text = Color(argb: look.text)
        let quiet = Color(argb: look.text, alpha: BannerLook.secondaryAlpha)
        Button(action: onOpen) {
            ZStack(alignment: .leading) {
                MixArtCanvas(art: art)
                if look.veilAlpha > 0 {
                    let veil = Color(argb: look.veil)
                    LinearGradient(stops: [
                        .init(color: veil.opacity(Double(look.veilAlpha)), location: 0),
                        .init(color: veil.opacity(Double(look.veilAlpha)), location: 0.5),
                        .init(color: veil.opacity(Double(look.veilAlpha * 0.4)), location: 0.64),
                        .init(color: veil.opacity(0), location: 0.82),
                    ], startPoint: .leading, endPoint: .trailing)
                }
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("SMART PLAYLIST").font(.caption2.weight(.medium)).foregroundStyle(quiet)
                        Text(mix.title).font(.title3.weight(.bold)).foregroundStyle(text).lineLimit(2)
                        Text(mix.description).font(.caption).foregroundStyle(quiet).lineLimit(2)
                        Spacer(minLength: 0)
                        HStack(spacing: Spacing.md) {
                            Button(action: onPlay) {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                                    Text("Play").font(.subheadline.weight(.bold))
                                }
                                .foregroundStyle(Color(argb: look.onText))
                                .padding(.leading, Spacing.md)
                                .padding(.trailing, Spacing.lg)
                                .frame(height: 40)
                                .background(Capsule().fill(text))
                            }
                            .pressable()
                            .accessibilityLabel("Play \(mix.title)")
                            Text(countLabel(mix.songIds.count, "song")).font(.caption).foregroundStyle(quiet).lineLimit(1)
                        }
                    }
                    .padding(Spacing.lg)
                    .frame(width: geometry.size.width * 0.54, height: geometry.size.height, alignment: .topLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityLabel("Open \(mix.title)")
    }
}

/// While history is short: the honest note, in the banner's shape and the theme's own colours.
private struct MoreListeningBanner: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Image(systemName: "waveform").foregroundStyle(palette.primary)
            Text("More mixes are on the way").font(.headline).foregroundStyle(palette.onSurfaceVariant)
            Text("Keep listening and empee3 will build mixes from your plays.").font(.caption).foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(palette.surfaceVariant))
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? palette.primary : palette.onSurface.opacity(0.32))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .frame(maxWidth: .infinity)
    }
}
