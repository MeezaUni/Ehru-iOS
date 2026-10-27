import SwiftUI
import UniformTypeIdentifiers

extension Tool {
    /// The tools ported so far; the rest join the menu as they arrive.
    static let available: [Tool] = [.soundCapsule, .equalizer, .autoFixTags, .artworkFetcher, .wifiTransfer, .settings]
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
        default: EmptyState(message: "\(tool.label) isn't available on iOS yet.", systemImage: tool.icon).navigationTitle(tool.label)
        }
    }
}

/// Settings: appearance, library and about.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @State private var importingTheme = false
    @State private var themeMessage: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Theme", selection: Binding(get: { settings.customTheme?.id ?? settings.theme.rawValue }, set: { value in
                    if let choice = ThemeChoice(rawValue: value) {
                        settings.useCustomTheme(nil)
                        settings.theme = choice
                    } else {
                        settings.useCustomTheme(value)
                    }
                })) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0.rawValue) }
                    ForEach(settings.importedThemes) { Text("\($0.name) (\($0.author))").tag($0.id) }
                }
                Button("Import a theme…") { importingTheme = true }
                if let theme = settings.customTheme {
                    Button("Delete \(theme.name)", role: .destructive) { settings.deleteTheme(theme.id) }
                }
                if let themeMessage { Text(themeMessage).font(.footnote).foregroundStyle(.secondary) }
                Toggle("Glass effect", isOn: $settings.glassEnabled)
                Toggle("Moving artwork in Now Playing", isOn: $settings.movingArtwork)
                Picker("Start on", selection: $settings.startSection) {
                    ForEach(LibrarySection.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Themes made for empee3 on Android (a .zip with a manifest.json, or the manifest itself) bring their colours; their fonts and widget skins aren't used on iOS.")
            }
            OnlineSourcesSection()
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
        .fileImporter(isPresented: $importingTheme, allowedContentTypes: [.zip, .json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let theme = try ThemeImporter.theme(from: try Data(contentsOf: url))
                settings.importTheme(theme)
                themeMessage = "Imported \(theme.name)."
            } catch {
                themeMessage = error.localizedDescription
            }
        }
        .navigationTitle("Settings")
    }
}

/// Personal API keys for the extra sources, kept in the Keychain on this phone only.
private struct OnlineSourcesSection: View {
    @State private var drafts: [APIKeyKind: String] = [:]
    @State private var saved: [APIKeyKind: Bool] = Dictionary(uniqueKeysWithValues: APIKeyKind.allCases.map { ($0, APIKeys.shared.isSet($0)) })

    var body: some View {
        Section {
            ForEach(APIKeyKind.allCases) { kind in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text(kind.label).font(.subheadline)
                        Spacer()
                        Text(saved[kind] == true ? "Saved" : "Not set").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        SecureField(saved[kind] == true ? "Paste a new one to replace it" : "Paste it here", text: Binding(
                            get: { drafts[kind] ?? "" }, set: { drafts[kind] = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button("Save") { save(kind, drafts[kind]) }
                            .disabled((drafts[kind] ?? "").trimmed.isEmpty)
                        if saved[kind] == true {
                            Button("Remove", role: .destructive) { save(kind, nil) }
                        }
                    }
                    .buttonStyle(.borderless)
                    Text(kind.help).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Online sources")
        } footer: {
            Text("Optional. Each key is your own, stored in this iPhone's Keychain only: never in the app's files or the repository, and not carried over to other devices. Without a key that source is simply skipped.")
        }
    }

    private func save(_ kind: APIKeyKind, _ value: String?) {
        APIKeys.shared.set(kind, value)
        saved[kind] = APIKeys.shared.isSet(kind)
        drafts[kind] = nil
        // A source refused with an old key may be asked again.
        Task { await AppServices.shared.fixTags.service.forgetRefusals() }
    }
}
