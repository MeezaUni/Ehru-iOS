import Foundation
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

        init() {}

        /// Older files without a field keep its default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            theme = try c.decodeIfPresent(ThemeChoice.self, forKey: .theme) ?? .system
            glassEnabled = try c.decodeIfPresent(Bool.self, forKey: .glassEnabled) ?? true
            startSection = try c.decodeIfPresent(String.self, forKey: .startSection) ?? LibrarySection.home.rawValue
            visualizer = (try? c.decodeIfPresent(VisualizerSettings.self, forKey: .visualizer)) ?? VisualizerSettings()
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

    private func update(_ change: (inout Stored) -> Void) {
        change(&stored)
        store.save(stored)
    }
}
