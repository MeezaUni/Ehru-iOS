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
    @Environment(SoundStore.self) private var sound
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsImporter = false
    @State private var chrome = LibraryChromeState()
    @State private var playerMotion = PlayerDragState()
    @State private var artworkFrames = PlayerArtworkFrames()
    @State private var visualBudget = VisualWorkBudget.current
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
                    .environment(\.motionCoverVisible, router.section == section && !playerMotion.isPresented)
                    .opacity(router.section == section ? 1 : 0)
                    .allowsHitTesting(router.section == section)
                    .accessibilityHidden(router.section != section)
            }
            if router.paths[router.section]?.isEmpty ?? true { drawerEdge }
            LibraryBottomChrome(chrome: chrome).zIndex(2)
            if let message = actions.message, !router.showsNowPlaying {
                LibraryChromeToast(text: message, id: actions.messageID, hasSong: player.state.currentSong != nil)
                    .zIndex(2)
            }
            drawer.zIndex(3)
        }
        .overlay {
            GeometryReader { geometry in
                ZStack {
                    if playerMotion.isPresented {
                        PlayerPresentation(drag: playerMotion, frames: artworkFrames)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .transition(.identity)
                            .zIndex(1)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onChange(of: geometry.size, initial: true) { _, size in playerMotion.travel = max(size.height * 0.65, 240) }
            }
            .allowsHitTesting(playerMotion.isPresented)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: router.showsDrawer)
        .coordinateSpace(name: PlayerArtworkSpace.root)
        .onPreferenceChange(PlayerArtworkFrameKey.self) { next in
            // The expanded placeholder stays fixed while its artwork overlay flies to the mini-player.
            if next.mini.width > 0 { artworkFrames.mini = next.mini }
            if next.expanded.width > 0 { artworkFrames.expanded = next.expanded }
        }
        .onChange(of: router.showsNowPlaying, initial: true) { _, shown in
            if shown && !playerMotion.isPresented { artworkFrames.expanded = .zero }
            playerMotion.setPresented(shown, reduceMotion: reduceMotion)
        }
        .animation(.easeInOut(duration: 0.2), value: actions.message)
        .environment(chrome)
        .environment(playerMotion)
        .environment(\.visualWorkBudget, visualBudget)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in visualBudget = .current }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: RunLoop.main)) { _ in visualBudget = .current }
        .onChange(of: router.section) { _, _ in chrome.expand(reduceMotion: reduceMotion) }
        .onChange(of: router.showsSearch) { _, _ in chrome.expand(reduceMotion: reduceMotion) }
        .onChange(of: router.paths[router.section]?.count) { _, _ in chrome.expand(reduceMotion: reduceMotion) }
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

/// Only this small overlay observes the animated chrome height, not the library screen tree.
private struct LibraryChromeToast: View {
    let text: String
    let id: UUID
    let hasSong: Bool
    @Environment(LibraryChromeState.self) private var chrome

    var body: some View {
        LibraryActionToast(text: text, id: id)
            .padding(.bottom, LibraryChromeGeometry(width: 0, fraction: chrome.fraction, hasSong: hasSong).height + Spacing.xs + Spacing.md)
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
