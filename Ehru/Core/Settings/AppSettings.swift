import Foundation
import SwiftUI
import Observation

/// The listener's app preferences (Android's ThemeRepository and friends), saved as JSON.
@MainActor
@Observable
final class AppSettings {
    struct Stored: Codable, Equatable {
        var theme: ThemeChoice = .system
        /// Glass material on floating surfaces, independent of the theme.
        var glassEnabled = true
        var startSection: String = LibrarySection.home.rawValue
        var visualizer = VisualizerSettings()
        /// An imported theme in use instead of [theme], by id.
        var customThemeId: String?
        var importedThemes: [ImportedTheme] = []

        init() {}

        /// Older files without a field keep its default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            theme = try c.decodeIfPresent(ThemeChoice.self, forKey: .theme) ?? .system
            glassEnabled = try c.decodeIfPresent(Bool.self, forKey: .glassEnabled) ?? true
            startSection = try c.decodeIfPresent(String.self, forKey: .startSection) ?? LibrarySection.home.rawValue
            visualizer = (try? c.decodeIfPresent(VisualizerSettings.self, forKey: .visualizer)) ?? VisualizerSettings()
            customThemeId = try? c.decodeIfPresent(String.self, forKey: .customThemeId)
            importedThemes = (try? c.decodeIfPresent([ImportedTheme].self, forKey: .importedThemes)) ?? []
        }
    }

    private(set) var stored: Stored
    @ObservationIgnored private let store = JSONStore<Stored>(name: "settings.json")

    init() { stored = store.load() ?? Stored() }

    var theme: ThemeChoice {
        get { stored.theme }
        set { update { $0.theme = newValue } }
    }

    var glassEnabled: Bool {
        get { stored.glassEnabled }
        set { update { $0.glassEnabled = newValue } }
    }

    var startSection: LibrarySection {
        get { LibrarySection(rawValue: stored.startSection) ?? .home }
        set { update { $0.startSection = newValue.rawValue } }
    }

    var visualizer: VisualizerSettings {
        get { stored.visualizer }
        set { update { $0.visualizer = newValue } }
    }

    /// The imported theme in use, if any.
    var customTheme: ImportedTheme? {
        stored.customThemeId.flatMap { id in stored.importedThemes.first { $0.id == id } }
    }

    var importedThemes: [ImportedTheme] { stored.importedThemes }

    /// The appearance the app asks for: an imported theme's own, else the chosen one.
    var colorScheme: ColorScheme? {
        if let customTheme { return customTheme.isDark ? .dark : .light }
        return theme.colorScheme
    }

    /// Adds (or replaces) a theme and switches to it.
    func importTheme(_ theme: ImportedTheme) {
        update { stored in
            stored.importedThemes.removeAll { $0.id == theme.id }
            stored.importedThemes.append(theme)
            stored.customThemeId = theme.id
        }
    }

    func useCustomTheme(_ id: String?) {
        update { $0.customThemeId = id }
    }

    func deleteTheme(_ id: String) {
        update { stored in
            stored.importedThemes.removeAll { $0.id == id }
            if stored.customThemeId == id { stored.customThemeId = nil }
        }
    }

    private func update(_ change: (inout Stored) -> Void) {
        change(&stored)
        store.save(stored)
    }
}
