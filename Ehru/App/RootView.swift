import SwiftUI
import UniformTypeIdentifiers

/// The app's frame (Android's MainScaffold): the four sections, each with its own back stack,
/// a glass bottom bar with the mini player above it, Search beside the sections, and the side menu
/// with the tools.
struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(SoundStore.self) private var sound
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.palette) private var palette
    @State private var showsImporter = false
    /// While a finger moves the side menu: how far it has pulled (positive opening, negative closing).
    @State private var drawerDrag: CGFloat?
    private static let drawerWidth: CGFloat = 300

    var body: some View {
        @Bindable var router = router
        @Bindable var library = library
        ZStack(alignment: .bottom) {
            palette.background.ignoresSafeArea()
            ForEach(LibrarySection.allCases) { section in
                sectionStack(section)
                    .environment(\.motionCoverVisible, router.section == section)
                    .opacity(router.section == section ? 1 : 0)
                    .allowsHitTesting(router.section == section)
                    .accessibilityHidden(router.section != section)
            }
            if router.paths[router.section]?.isEmpty ?? true { drawerEdge }
            bottomChrome.zIndex(2)
            if let message = actions.message, !router.showsNowPlaying {
                Toast(text: message)
                    .padding(.bottom, player.state.currentSong == nil ? 96 : 160)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { if actions.message == message { actions.message = nil } }
                    }
            }
            drawer.zIndex(3)
        }
        .overlay {
            GeometryReader { geometry in
                ZStack {
                    if router.showsNowPlaying {
                        PlayerPresentation()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            // Move beyond both unsafe edges too, so the outgoing header cannot
                            // remain visible over the home indicator at the end of dismissal.
                            .transition(.offset(y: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom + 1))
                            .zIndex(1)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .allowsHitTesting(router.showsNowPlaying)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: router.showsDrawer)
        .animation(.smooth(duration: 0.32), value: router.showsNowPlaying)
        .animation(.easeInOut(duration: 0.2), value: actions.message)
        .sheet(isPresented: $router.showsSearch) { SearchView() }
        .routerSheets(active: !router.showsNowPlaying)
        .alert("New playlist", isPresented: $router.showsNewPlaylist) { NewPlaylistAlert() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .alert("Something went wrong", isPresented: $library.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onAppear { library.scan() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.scan() }
            if phase == .background {
                player.persistNow()
                sound.persistNow()
            }
        }
    }

    private func sectionStack(_ section: LibrarySection) -> some View {
        NavigationStack(path: router.binding(for: section)) {
            sectionRoot(section)
                .navigationTitle(section == .home ? "empee3" : section.label)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { router.showsDrawer = true } label: { Image(systemName: "line.3.horizontal") }
                            .accessibilityLabel("Menu")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showsImporter = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add music")
                    }
                }
                .navigationDestination(for: Route.self) { route in destination(route) }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: chromeHeight) }
        }
        .environment(\.artworkSection, section)
    }

    @ViewBuilder
    private func sectionRoot(_ section: LibrarySection) -> some View {
        switch section {
        case .home: HomeView()
        case .albums: AlbumsView()
        case .library: LibraryOverviewView()
        case .vybe: VybeView()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        Group {
            switch route {
            case .album(let id): AlbumDetailView(albumId: id)
            case .artist(let id): ArtistDetailView(artistId: id)
            case .playlist(let id): PlaylistDetailView(playlistId: id)
            case .smartPlaylist(let key): SmartPlaylistDetailView(mixKey: key)
            case .shelf(let shelf): LibraryShelfView(shelf: shelf)
            case .allSongs: AllSongsView()
            case .tool(let tool): ToolView(tool: tool)
            case .transitionStudio(let collection): TransitionStudioView(collection: collection)
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: chromeHeight) }
    }

    private var chromeHeight: CGFloat { player.state.currentSong == nil ? 72 : 136 }

    private var bottomChrome: some View {
        VStack(spacing: Spacing.sm) {
            if let song = player.state.currentSong {
                MiniPlayer(song: song) { router.showsNowPlaying = true }
                    .glassSurface(cornerRadius: Radius.large, enabled: settings.glassEnabled)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: Spacing.sm) {
                HStack(spacing: 0) {
                    ForEach(LibrarySection.allCases) { section in
                        Button { router.select(section) } label: {
                            VStack(spacing: 2) {
                                Image(systemName: router.section == section ? section.selectedIcon : section.icon).font(.system(size: 19))
                                Text(section.label).font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(router.section == section ? palette.primary : palette.onSurfaceVariant)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(router.section == section ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Spacing.xs)
                .glassSurface(cornerRadius: 28, enabled: settings.glassEnabled)
                Button { router.showsSearch = true } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(palette.onSurface)
                        .frame(width: 56, height: 56)
                        .glassSurface(cornerRadius: 28, enabled: settings.glassEnabled)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xs)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.state.currentSong == nil)
    }

    /// A swipe in from the left edge opens the side menu (on a section's first page; deeper pages
    /// keep the edge for going back).
    private var drawerEdge: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in drawerDrag = max(value.translation.width, 0) }
                    .onEnded { value in settleDrawer(open: value.translation.width > 100 || value.predictedEndTranslation.width > 220) })
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: .vertical)
    }

    /// How much of the side menu shows (0 closed … its width open): it follows the finger, then settles.
    private var drawerShown: CGFloat {
        if router.showsDrawer { return Self.drawerWidth + min(drawerDrag ?? 0, 0) }
        return min(max(drawerDrag ?? 0, 0), Self.drawerWidth)
    }

    private func settleDrawer(open: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            router.showsDrawer = open
            drawerDrag = nil
        }
    }

    private var drawer: some View {
        let shown = max(drawerShown, 0)
        return ZStack(alignment: .leading) {
            Color.black.opacity(0.35 * Double(shown / Self.drawerWidth)).ignoresSafeArea()
                .onTapGesture { settleDrawer(open: false) }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("empee3").font(.largeTitle.weight(.bold)).padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.lg)
                drawerItem("Library", icon: "books.vertical") {
                    router.showsDrawer = false
                    router.paths[router.section] = NavigationPath()
                }
                ForEach(Tool.available) { tool in
                    drawerItem(tool.label, icon: tool.icon) { router.open(tool) }
                }
                Spacer()
            }
            .frame(width: Self.drawerWidth)
            .frame(maxHeight: .infinity)
            .background(palette.surface.ignoresSafeArea())
            .offset(x: shown - Self.drawerWidth)
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { value in drawerDrag = min(value.translation.width, 0) }
                .onEnded { value in settleDrawer(open: !(value.translation.width < -100 || value.predictedEndTranslation.width < -220)) })
        }
        .allowsHitTesting(shown > 0)
        .accessibilityHidden(shown == 0)
    }

    private func drawerItem(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.lg) {
                Image(systemName: icon).frame(width: 24)
                Text(label).font(.body.weight(.medium))
                Spacer()
            }
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, Spacing.lg)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// The song sheets anyone can ask the router for, presented by whichever screen is on top
    /// ([active]): the root, or Now Playing over it (a sheet from the root would open behind it).
    func routerSheets(active: Bool) -> some View { modifier(RouterSheets(active: active)) }
}

private struct RouterSheets: ViewModifier {
    let active: Bool
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { active ? router.songsForPlaylist.map(SongBatch.init) : nil }, set: { router.songsForPlaylist = $0?.songs })) { batch in
                AddToPlaylistSheet(songs: batch.songs)
            }
            .sheet(item: Binding(get: { active ? router.songForDetails : nil }, set: { router.songForDetails = $0 })) { song in
                SongDetailsSheet(song: song)
            }
            .sheet(item: Binding(get: { active ? router.songForTagEdit : nil }, set: { router.songForTagEdit = $0 })) { song in
                EditTagsSheet(song: song)
            }
    }
}

/// Songs being added to a playlist (identifiable for the sheet).
private struct SongBatch: Identifiable {
    let songs: [Song]
    var id: [Int64] { songs.map(\.id) }
}

/// Pick a playlist for [songs], or create one with them.
struct AddToPlaylistSheet: View {
    let songs: [Song]
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: { Label("New playlist", systemImage: "plus") }
                ForEach(library.playlists) { playlist in
                    Button {
                        actions.add(songs, to: playlist)
                        dismiss()
                    } label: {
                        HStack(spacing: Spacing.md) {
                            PlaylistCoverView(playlist: playlist)
                                .frame(width: ArtworkSize.compact, height: ArtworkSize.compact)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                            VStack(alignment: .leading) {
                                Text(playlist.name).foregroundStyle(.primary)
                                Text(countLabel(playlist.songCount, "song")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(songs.count == 1 ? "Add \"\(songs[0].title)\"" : "Add \(countLabel(songs.count, "song"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
            .alert("New playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    actions.createPlaylist(newName, songs: songs)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The "New playlist" dialog's field and buttons.
private struct NewPlaylistAlert: View {
    @Environment(LibraryActions.self) private var actions
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
        Button("Cancel", role: .cancel) {}
        Button("Create") { actions.createPlaylist(name) }
    }
}

/// What the library knows about a song: its tags and its file.
struct SongDetailsSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Spacing.md) {
                        SongArtworkView(song: song, maxPixels: 300)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                        VStack(alignment: .leading) {
                            Text(song.title).font(.headline)
                            Text(song.artist).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Tags") {
                    row("Title", song.title)
                    row("Artist", song.artist)
                    row("Album", song.album)
                    row("Track", song.trackNumber > 0 ? "\(song.trackNumber)" : nil)
                    row("Disc", song.discNumber > 0 ? "\(song.discNumber)" : nil)
                    row("Year", song.year > 0 ? "\(song.year)" : nil)
                    row("Genre", song.genre)
                    row("BPM", song.bpm.map(String.init))
                    row("Composer", song.composer)
                }
                Section("File") {
                    row("Duration", formatDuration(song.durationMs))
                    row("Format", song.codec)
                    row("Sample rate", song.sampleRate > 0 ? String(format: "%.1f kHz", Double(song.sampleRate) / 1000) : nil)
                    row("Bit rate", song.bitrate > 0 ? "\(song.bitrate / 1000) kbps" : nil)
                    row("Channels", song.channels > 0 ? "\(song.channels)" : nil)
                    row("Size", song.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file) : nil)
                    row("Path", song.path)
                }
            }
            .navigationTitle("Music information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isBlank {
            LabeledContent(label) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
        }
    }
}
