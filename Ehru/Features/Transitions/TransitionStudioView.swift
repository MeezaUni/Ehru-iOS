import SwiftUI

/// Colours of the automation lanes, fixed so they read the same in every theme.
enum AutomationColors {
    static let volume = Color(argb: 0xFF4FB6EA)
    static let eq = Color(argb: 0xFFF2C744)
    static let filter = Color(argb: 0xFFE98BE6)
}

private func noun(_ collection: CollectionRef) -> String { collection.kind == .album ? "album" : "playlist" }

/// The compact entry row on an album or playlist page: shows this collection's transition state, opens the Studio.
struct TransitionStudioRow: View {
    let collection: CollectionRef
    @Environment(TransitionSettingsStore.self) private var transitions
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette

    var body: some View {
        let config = transitions.config
        let choice = config.collection(collection)
        let custom = config.pairs.keys.filter { $0.collection == collection }.count
        Button { router.open(.transitionStudio(collection)) } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(palette.onSurfaceVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transition Studio").font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface)
                    Text(summary(config, choice) + (custom > 0 ? " · \(custom) custom" : ""))
                        .font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Transition Studio")
    }

    private func summary(_ config: TransitionConfig, _ choice: TransitionChoice) -> String {
        if !config.global.masterEnabled { return "Automatic crossfades are off" }
        switch choice {
        case .off: return "Off for this \(noun(collection))"
        case .custom(let spec): return specSummary(spec)
        case .inherit: return "Default · \(specSummary(config.global.defaultChoice.specOrNil))"
        }
    }
}

/// Transition Studio for one album or playlist: the app-wide switch and default, this collection's
/// setting, and the timeline of its tracks with the transition between each pair.
struct TransitionStudioView: View {
    let collection: CollectionRef
    @Environment(TransitionSettingsStore.self) private var transitions
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette
    @State private var tracks: [StudioTrack] = []
    @State private var draft: EditorDraft?

    var body: some View {
        let config = transitions.config
        let pairs = studioPairs(collection, tracks: tracks, config: config)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.md) {
                Text(title).font(.subheadline).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                globalPanel(config)
                collectionPanel(config)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Transitions").font(.title3.weight(.semibold))
                    Text("Tap a transition to edit that exact pair. With shuffle, a pair's setting applies whenever those two tracks play back to back; Auto follows the \(noun(collection))'s setting.")
                        .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                }
                .padding(.top, Spacing.sm)
                if tracks.count < 2 {
                    Text("Add at least two tracks to set up transitions between them.")
                        .font(.footnote).foregroundStyle(palette.onSurfaceVariant)
                }
                ForEach(Array(tracks.enumerated()), id: \.element.occurrence) { index, track in
                    let pair = pairs.indices.contains(index) ? pairs[index] : nil
                    VStack(alignment: .leading, spacing: 0) {
                        StudioTrackRow(track: track, pair: pair, onEdit: { open(.pair($0)) },
                                       onReset: { transitions.setPair($0.key, .inherit) })
                        if let pair {
                            PairConnector(pair: pair, enabled: config.global.masterEnabled) { open(.pair(pair)) }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.xxl)
        }
        .navigationTitle("Transition Studio")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { _ in
            TransitionEditorView(draft: $draft, noun: noun(collection))
        }
        .task(id: library.songs) { load() }
        .task(id: library.playlists) { load() }
    }

    private var title: String {
        switch collection.kind {
        case .album: library.album(collection.id)?.title ?? "Album"
        case .playlist: library.playlist(collection.id)?.name ?? "Playlist"
        }
    }

    private func open(_ target: EditorTarget) {
        draft = EditorDraft.open(target, config: transitions.config)
    }

    private func load() {
        let db = library.database
        switch collection.kind {
        case .album:
            tracks = ((try? db.songsOfAlbum(collection.id)) ?? []).map { StudioTrack(song: $0, occurrence: TrackOccurrence($0.id)) }
        case .playlist:
            tracks = ((try? db.playlistEntries(collection.id)) ?? []).map {
                StudioTrack(song: $0.song, occurrence: TrackOccurrence($0.song.id, $0.position))
            }
        }
    }

    private func globalPanel(_ config: TransitionConfig) -> some View {
        StudioPanel {
            Toggle(isOn: Binding(get: { config.global.masterEnabled }, set: { enabled in
                var global = transitions.config.global
                global.masterEnabled = enabled
                transitions.setGlobal(global)
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic crossfades").font(.subheadline.weight(.semibold))
                    Text("Master switch for every transition in the app. Off keeps all settings but plays tracks back to back.")
                        .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default for all music").font(.subheadline)
                    Text(specSummary(config.global.defaultChoice.specOrNil)).font(.caption).foregroundStyle(palette.onSurfaceVariant)
                }
                Spacer()
                Button("Edit") { open(.global) }
            }
        }
    }

    private func collectionPanel(_ config: TransitionConfig) -> some View {
        let choice = config.collection(collection)
        let isPlaying = player.state.currentCollection == collection
        return StudioPanel {
            Text("This \(noun(collection))").font(.subheadline.weight(.semibold))
            Picker("This \(noun(collection))", selection: Binding(get: { segment(choice) }, set: { picked in
                switch picked {
                case 0: transitions.setCollection(collection, .inherit)
                case 1: transitions.setCollection(collection, .off)
                default: open(.collection(collection))
                }
            })) {
                Text("Default").tag(0)
                Text("Off").tag(1)
                Text("Custom").tag(2)
            }
            .pickerStyle(.segmented)
            Text(collectionStatus(config, choice) + (isPlaying ? " Playing now." : ""))
                .font(.caption).foregroundStyle(palette.onSurfaceVariant)
            if case .custom = choice {
                HStack(spacing: Spacing.lg) {
                    Button("Edit") { open(.collection(collection)) }
                    Button("Reset to default") { transitions.setCollection(collection, .inherit) }
                }
                .font(.subheadline)
            }
            if !config.global.masterEnabled {
                Text("Automatic crossfades are off, so nothing here plays until the master switch is on.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func segment(_ choice: TransitionChoice) -> Int {
        switch choice {
        case .inherit: 0
        case .off: 1
        case .custom: 2
        }
    }

    private func collectionStatus(_ config: TransitionConfig, _ choice: TransitionChoice) -> String {
        switch choice {
        case .inherit: "Uses the default: \(specSummary(config.global.defaultChoice.specOrNil))."
        case .off: "No crossfades in this \(noun(collection)), whatever the default."
        case .custom(let spec): "Its own transition: \(specSummary(spec))."
        }
    }
}

/// A rounded panel of related settings.
struct StudioPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) { content() }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surfaceVariant.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct StudioTrackRow: View {
    let track: StudioTrack
    let pair: StudioPair?
    let onEdit: (StudioPair) -> Void
    let onReset: (StudioPair) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.md) {
            SongArtworkView(song: track.song, maxPixels: 144)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.song.title).font(.body).lineLimit(1)
                Text("\(track.song.artist) · \(formatDuration(track.song.durationMs))")
                    .font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let pair {
                Menu {
                    Button { onEdit(pair) } label: { Label("Edit transition to next", systemImage: "slider.horizontal.3") }
                    if pair.choice != .inherit {
                        Button { onReset(pair) } label: { Label("Reset transition to Auto", systemImage: "arrow.uturn.backward") }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .foregroundStyle(palette.onSurfaceVariant)
                .accessibilityLabel("More for \(track.song.title)")
            }
        }
    }
}

private struct PairConnector: View {
    let pair: StudioPair
    let enabled: Bool
    let onTap: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Rectangle().fill(palette.outline).frame(width: 2, height: 40).padding(.leading, 23)
            Button(action: onTap) {
                Text(pairLabel(pair.choice))
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 6)
                    .background(palette.surfaceVariant, in: Capsule())
                    .overlay(Capsule().stroke(pair.choice == .inherit ? Color.clear : AutomationColors.volume, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transition to \(pair.to.song.title): \(pairLabel(pair.choice))")
            Text(enabled ? specSummary(pair.resolved) : "Off (master switch)")
                .font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
        }
    }
}
