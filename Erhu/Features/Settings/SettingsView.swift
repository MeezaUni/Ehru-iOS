import SwiftUI
import UniformTypeIdentifiers

/// The Android settings groups, adapted to the controls and tools available on iOS.
struct SettingsView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                SettingsGroup("Personalize") {
                    SettingsLink("Themes & Appearance", subtitle: "Colours, themes and appearance", icon: "paintpalette.fill") {
                        AppearanceSettingsView()
                    }
                }
                SettingsGroup("Sound") {
                    SettingsLink("Audio & Equalizer", subtitle: "8-band equalizer, presets and audio effects", icon: "chart.bar.fill") {
                        EqualizerView()
                    }
                    SettingsLink("Visualizer", subtitle: "Style and feel of the Now Playing visualizer", icon: "waveform") {
                        VisualizerSettingsView()
                    }
                }
                SettingsGroup("Library") {
                    SettingsLink("Music Library", subtitle: "Music folder, scanning and your collection", icon: "folder.fill") {
                        LibrarySettingsView()
                    }
                    SettingsLink("Metadata & Artwork", subtitle: "Tags, cover art and online sources", icon: "number") {
                        MetadataSettingsView()
                    }
                }
                SettingsGroup("About") {
                    SettingsLink("About Erhu", subtitle: "Version, privacy and source code", icon: "info.circle.fill") {
                        AboutSettingsView()
                    }
                }
            }
            .padding(Spacing.lg)
            .padding(.bottom, Spacing.lg)
        }
        .background(palette.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.onSurfaceVariant)
                .padding(.horizontal, Spacing.lg)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

private struct SettingsIcon: View {
    let symbol: String
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(palette.onSurface)
            .frame(width: size, height: size)
            .background(palette.onSurface.opacity(0.09), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct SettingsLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let destination: Destination
    @Environment(\.palette) private var palette

    init(_ title: String, subtitle: String, icon: String, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination.modifier(SettingsDetailClearance())
        } label: {
            HStack(spacing: Spacing.lg) {
                SettingsIcon(symbol: icon)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(palette.onSurface)
                    Text(subtitle).font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.lg)
            .frame(minHeight: 88)
            .contentShape(Rectangle())
        }
        .pressable()
    }
}

/// View-based pushes need the same clearance as the router's destinations above the mini player.
private struct SettingsDetailClearance: ViewModifier {
    @Environment(PlayerController.self) private var player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: player.state.currentSong == nil ? 72 : 136)
        }
    }
}

/// Keep native controls, pickers and back navigation on each detail page.
private struct SettingsFormStyle: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings
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
                Button { importingTheme = true } label: {
                    Label("Import a theme…", systemImage: "square.and.arrow.down")
                }
                if let theme = settings.customTheme {
                    Button(role: .destructive) { settings.deleteTheme(theme.id) } label: {
                        Label("Delete \(theme.name)", systemImage: "trash")
                    }
                }
                if let themeMessage { Text(themeMessage).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Theme")
            } footer: {
                Text("Import colours from an Android theme ZIP or its manifest.json. Fonts and widget skins are not imported.")
            }
            if Tool(rawValue: "animatedArtwork") != nil {
                Section {
                    Toggle("Moving artwork in Now Playing", isOn: $settings.movingArtwork)
                } header: {
                    Text("Player artwork")
                } footer: {
                    Text("Gently moves the cover while music plays. iOS Reduce Motion and Low Power Mode are respected.")
                }
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
        .navigationTitle("Themes & Appearance")
        .modifier(SettingsFormStyle())
    }
}

private struct VisualizerSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var showingVisualizer = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Style") {
                Picker("Mode", selection: $settings.visualizer.mode) {
                    ForEach(VisualizerMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Response") {
                Picker("Sensitivity", selection: $settings.visualizer.sensitivity) {
                    Text("Low").tag(VisualizerSensitivity.low)
                    Text("Normal").tag(VisualizerSensitivity.normal)
                    Text("High").tag(VisualizerSensitivity.high)
                }
                Picker("Smoothing", selection: $settings.visualizer.smoothing) {
                    Text("Responsive").tag(VisualizerSmoothing.responsive)
                    Text("Balanced").tag(VisualizerSmoothing.balanced)
                    Text("Smooth").tag(VisualizerSmoothing.smooth)
                }
                Toggle("Reduce motion", isOn: $settings.visualizer.reduceMotion)
            }
            Section {
                Button { showingVisualizer = true } label: {
                    Label("Open visualizer", systemImage: "waveform")
                }
            } footer: {
                Text("These options also apply when you open the visualizer from Now Playing.")
            }
        }
        .sheet(isPresented: $showingVisualizer) { VisualizerView() }
        .navigationTitle("Visualizer")
        .modifier(SettingsFormStyle())
    }
}

private struct LibrarySettingsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Form {
            Section {
                Label("On My iPhone › Erhu", systemImage: "folder.fill")
            } header: {
                Text("Music folder")
            } footer: {
                Text("Add music with the Files app, the + button, or Wi-Fi Transfer. Erhu scans its Documents folder.")
            }
            Section("Scan") {
                Button { library.scan() } label: {
                    Label("Rescan library now", systemImage: "arrow.clockwise")
                }
                .disabled(library.isScanning)
                if let progress = library.scanProgress {
                    HStack(spacing: Spacing.md) {
                        ProgressView()
                        Text("Scanning \(progress.scanned) of \(progress.total)…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Your collection") {
                LabeledContent("Songs", value: "\(library.songs.count)")
                LabeledContent("Albums", value: "\(library.albums.count)")
                LabeledContent("Artists", value: "\(library.artists.count)")
            }
        }
        .navigationTitle("Music Library")
        .modifier(SettingsFormStyle())
    }
}

private struct MetadataSettingsView: View {
    var body: some View {
        Form {
            Section("Tags & cover art") {
                NavigationLink { FixTagsView().modifier(SettingsDetailClearance()) } label: {
                    Label("Auto Fix Tags", systemImage: "wand.and.stars")
                }
                NavigationLink { ArtworkFetcherView().modifier(SettingsDetailClearance()) } label: {
                    Label("Artwork Fetcher", systemImage: "photo.on.rectangle.angled")
                }
                // The tool exists only in the animated-art branch; never offer a dead destination.
                if let motion = Tool(rawValue: "animatedArtwork"), Tool.available.contains(motion) {
                    NavigationLink { ToolView(tool: motion).modifier(SettingsDetailClearance()) } label: {
                        Label(motion.label, systemImage: motion.icon)
                    }
                }
            }
            OnlineSourcesSection()
        }
        .navigationTitle("Metadata & Artwork")
        .modifier(SettingsFormStyle())
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.lg) {
                    SettingsIcon(symbol: "music.note")
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Erhu").font(.title3.weight(.semibold))
                        Text("Your music, on your iPhone.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.sm)
                }
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–")
            }
            Section("Privacy") {
                Label("Music stays on your iPhone", systemImage: "iphone")
                Text("Your music files, library index and VYBE processing stay on this device. Online lyrics, metadata and artwork searches use the song or artist details needed for the request.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Link(destination: URL(string: "https://github.com/MeezaUni/Erhu-iOS")!) {
                    Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .navigationTitle("About Erhu")
        .modifier(SettingsFormStyle())
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
                        SettingsIcon(symbol: symbol(kind))
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

    private func symbol(_ kind: APIKeyKind) -> String {
        switch kind {
        case .lastFm: "waveform"
        case .fanartTv: "photo.fill.on.rectangle.fill"
        case .discogs: "opticaldisc"
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
