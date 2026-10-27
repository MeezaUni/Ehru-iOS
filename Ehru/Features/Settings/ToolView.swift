import SwiftUI

extension Tool {
    /// The tools ported so far; the rest join the menu as they arrive.
    static let available: [Tool] = [.soundCapsule, .equalizer, .autoFixTags, .wifiTransfer, .settings]
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
        default: EmptyState(message: "\(tool.label) isn't available on iOS yet.", systemImage: tool.icon).navigationTitle(tool.label)
        }
    }
}

/// Settings: appearance, library and about.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Glass effect", isOn: $settings.glassEnabled)
                Picker("Start on", selection: $settings.startSection) {
                    ForEach(LibrarySection.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Button("Rescan music folder") { library.scan() }
                    .disabled(library.isScanning)
                if let progress = library.scanProgress {
                    Text("Scanning \(progress.scanned) of \(progress.total)…").foregroundStyle(.secondary)
                }
                LabeledContent("Songs", value: "\(library.songs.count)")
                LabeledContent("Albums", value: "\(library.albums.count)")
                LabeledContent("Artists", value: "\(library.artists.count)")
            } header: {
                Text("Library")
            } footer: {
                Text("empee3 plays the music in its Documents folder. Add files with the Files app (On My iPhone › empee3), the + button, or over Wi-Fi.")
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                Text("Everything runs on this phone: your music, its index and VYBE never leave it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
