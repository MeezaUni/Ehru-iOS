import SwiftUI
import Observation

/// The primary destinations, switched by the bottom bar (Search is the separate button beside it).
enum LibrarySection: String, CaseIterable, Identifiable {
    case home, albums, library, vybe
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Home"
        case .albums: "Albums"
        case .library: "Library"
        case .vybe: "VYBE"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .albums: "square.stack"
        case .library: "music.note.house"
        case .vybe: "sparkles"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: "house.fill"
        case .albums: "square.stack.fill"
        case .library: "music.note.house.fill"
        case .vybe: "sparkles"
        }
    }
}

/// The full shelves the Library overview opens with "More".
enum LibraryShelf: String, Hashable {
    case playlists, favorites, artists

    var label: String {
        switch self {
        case .playlists: "Playlists"
        case .favorites: "Favorites"
        case .artists: "Artists"
        }
    }
}

/// The tools in the side menu (Android's navigation drawer).
enum Tool: String, CaseIterable, Identifiable, Hashable {
    case soundCapsule, equalizer, autoFixTags, libraryBuilder, artworkFetcher, wifiTransfer, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .soundCapsule: "Sound Capsule"
        case .equalizer: "Equalizer"
        case .autoFixTags: "Auto Fix Tags"
        case .libraryBuilder: "Library Builder"
        case .artworkFetcher: "Artwork Fetcher"
        case .wifiTransfer: "Wi-Fi Transfer"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .soundCapsule: "chart.bar.xaxis"
        case .equalizer: "slider.vertical.3"
        case .autoFixTags: "wand.and.stars"
        case .libraryBuilder: "folder"
        case .artworkFetcher: "photo.on.rectangle.angled"
        case .wifiTransfer: "wifi"
        case .settings: "gearshape"
        }
    }
}

/// A page pushed inside a section.
enum Route: Hashable {
    case album(Int64)
    case artist(Int64)
    case playlist(Int64)
    case smartPlaylist(String)
    case shelf(LibraryShelf)
    case allSongs
    case tool(Tool)
}

/// Where the app is: the section, each section's own back stack, and what is presented on top.
@MainActor
@Observable
final class AppRouter {
    var section: LibrarySection = .home
    var paths: [LibrarySection: NavigationPath] = Dictionary(uniqueKeysWithValues: LibrarySection.allCases.map { ($0, NavigationPath()) })
    var showsSearch = false
    var showsDrawer = false
    var showsNowPlaying = false
    var songsForPlaylist: [Song]?
    var songForDetails: Song?
    var showsNewPlaylist = false

    func open(_ route: Route) {
        paths[section, default: NavigationPath()].append(route)
    }

    func open(_ tool: Tool) {
        showsDrawer = false
        open(.tool(tool))
    }

    /// Selecting the current section again returns it to its first page.
    func select(_ target: LibrarySection) {
        if target == section {
            paths[target] = NavigationPath()
        } else {
            section = target
        }
    }

    func binding(for section: LibrarySection) -> Binding<NavigationPath> {
        Binding(get: { self.paths[section] ?? NavigationPath() }, set: { self.paths[section] = $0 })
    }

    func songActions(_ actions: LibraryActions, hideFromMixes: ((Song) -> Void)? = nil) -> SongActions {
        SongActions(
            toggleFavorite: { actions.toggleFavorite($0) },
            playNext: { actions.playNext($0) },
            addToQueue: { actions.addToQueue($0) },
            startRadio: { actions.startRadio(.song($0.id)) },
            addToPlaylist: { [weak self] song in self?.songsForPlaylist = [song] },
            viewDetails: { [weak self] song in self?.songForDetails = song },
            hideFromMixes: hideFromMixes
        )
    }
}
