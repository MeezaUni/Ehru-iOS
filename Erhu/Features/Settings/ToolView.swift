import SwiftUI

extension Tool {
    /// The tools ported so far; the rest join the menu as they arrive.
    static let available: [Tool] = [.soundCapsule, .equalizer, .autoFixTags, .artworkFetcher, .animatedArtwork, .wifiTransfer, .settings]
}

/// A tool page from the side menu.
struct ToolView: View {
    let tool: Tool

    var body: some View {
        switch tool {
        case .settings: SettingsView()
        case .equalizer: EqualizerView()
        case .soundCapsule: SoundCapsuleView()
        case .wifiTransfer: WifiTransferView()
        case .autoFixTags: FixTagsView()
        case .artworkFetcher: ArtworkFetcherView()
        case .animatedArtwork: AnimatedArtworkView()
        default: EmptyState(message: "\(tool.label) isn't available on iOS yet.", systemImage: tool.icon).navigationTitle(tool.label)
        }
    }
}
