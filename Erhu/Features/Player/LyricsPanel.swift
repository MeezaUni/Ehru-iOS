import SwiftUI

/// The playing song's lyrics: synced lines follow the music (the current line bright, its words lit
/// as they are sung when the lyrics time them), a tap on a line seeks to it; plain lyrics scroll.
/// Without lyrics it shows what the online lookup is doing, never invented text. It sits on a
/// surface in the artwork's colours, with text colours checked for contrast against it.
struct LyricsPanel: View {
    let song: Song
    /// Set for Now Playing's card (Android's LyricsPanel): a "Lyrics" heading with this expand
    /// button, smaller lines, on the artwork-coloured card. Nil: the full-screen lyrics, with the
    /// source and the lyrics options, drawn on whatever is behind.
    var onExpand: (() -> Void)?
    @Environment(\.palette) private var palette
    @State private var artworkPalette = ArtworkPaletteState()
    @State private var artworkRevision = 0

    var body: some View {
        let colors = LyricsColors(artworkPalette.palette(for: song.url))
        let shape = RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        LyricsPanelContent(song: song, onExpand: onExpand)
            .environment(\.palette, palette.lyrics(colors))
            .environment(\.lyricsColors, colors)
            .environment(\.lyricsCompact, onExpand != nil)
            .background { if onExpand != nil { CardSurface(colors: colors, shape: shape) } }
            .clipShape(shape)
            .onReceive(NotificationCenter.default.publisher(for: ArtworkLoader.didChange)) { note in
                if note.object as? String == song.url.path { artworkRevision += 1 }
            }
            .task(id: "\(song.url.path)|\(artworkRevision)") {
                // Resolve cached colours synchronously; this task only fills a cold or edited cover.
                let revision = ArtworkLoader.shared.revision(for: song.url.path)
                let next = await LyricsPaletteCache.shared.palette(for: song.url)
                guard !Task.isCancelled else { return }
                artworkPalette.set(next, for: song.url, revision: revision)
            }
    }
}

/// Now Playing's card material (Android's carouselCardSurface without glass): the artwork's card
/// gradient falling from the top-leading corner, with a rim bright along the top.
struct CardSurface<S: InsettableShape>: View {
    let colors: LyricsColors
    let shape: S

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(colors: colors.cardGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: colors.rim.opacity(0.5), location: 0),
                .init(color: colors.rim.opacity(0.12), location: 0.5),
                .init(color: .black.opacity(0.22), location: 1),
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
    }
}

private struct LyricsCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Lyrics set for the small card in Now Playing: smaller lines, the current one nearer the top.
    var lyricsCompact: Bool {
        get { self[LyricsCompactKey.self] }
        set { self[LyricsCompactKey.self] = newValue }
    }
}

extension AppPalette {
    /// This palette with the lyrics colours for text: current line, other lines, the timed word.
    func lyrics(_ colors: LyricsColors) -> AppPalette {
        AppPalette(primary: colors.accent, onPrimary: colors.surface, background: background, surface: colors.surface,
                   surfaceVariant: colors.content.opacity(0.12), onSurface: colors.content,
                   onSurfaceVariant: colors.secondary, outline: colors.secondary.opacity(0.4))
    }
}

private struct LyricsPanelContent: View {
    let song: Song
    let onExpand: (() -> Void)?
    @Environment(LyricsStore.self) private var store
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette
    @Environment(\.lyricsCompact) private var compact
    @State private var searching = false
    @State private var searchText = ""

    var body: some View {
        let lyrics = store.current?.songId == song.id ? store.current : nil
        VStack(spacing: 0) {
            if let onExpand { cardHeader(lyrics, onExpand) } else { header(lyrics) }
            if let lyrics, let parsed = lyrics.parsed {
                if let notice = lyrics.syncedServiceNotice {
                    Text(notice).font(.caption).foregroundStyle(palette.onSurfaceVariant)
                        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.xs)
                }
                switch parsed {
                case .synced(let lines): SyncedLyricsView(lyrics: parsed, lines: lines)
                case .plain(let lines): plain(lines)
                }
            } else if let onExpand {
                lookupLine(lyrics?.lookup ?? .idle, onExpand)
            } else {
                status(lyrics?.lookup ?? .idle)
            }
        }
        .task(id: song.id) { store.shown(song) }
        .sheet(isPresented: $searching, onDismiss: { store.closeSearch() }) {
            searchSheet.task { if !searchText.isBlank { store.search(searchText) } }
        }
    }

    private func cardHeader(_ lyrics: SongLyrics?, _ onExpand: @escaping () -> Void) -> some View {
        let plain = if case .plain? = lyrics?.parsed { true } else { false }
        return HStack {
            Text(plain ? "Lyrics · not synced" : "Lyrics").font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface)
            Spacer()
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.onSurface)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand lyrics")
        }
        .padding(.leading, Spacing.lg)
        .padding(.trailing, Spacing.xs)
        .padding(.top, Spacing.xs)
    }

    /// No lyrics text (yet) in the card: what the lookup is doing, never invented lyrics.
    private func lookupLine(_ lookup: LyricsLookup, _ onExpand: @escaping () -> Void) -> some View {
        let text = switch lookup {
        case .idle: "Lyrics unavailable"
        case .searching: "Looking for lyrics…"
        case .notFound: "No synced lyrics found · search online"
        case .instrumental: "Instrumental"
        case .offline: "Offline · synced lyrics couldn’t be checked"
        case .rateLimited: "Lyrics lookup paused for a moment"
        case .failed(let reason): reason.contains("LRCLIB") ? "LRCLIB synced lyrics are temporarily unavailable" : "Synced lyrics couldn’t be checked · tap to retry"
        }
        return Button(action: onExpand) {
            Text(text).font(.headline).foregroundStyle(palette.onSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func header(_ lyrics: SongLyrics?) -> some View {
        HStack {
            Text(origin(lyrics)).font(.caption.weight(.semibold)).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            Spacer()
            Menu {
                Button { store.refresh() } label: { Label("Refresh online lyrics", systemImage: "arrow.clockwise") }
                Button {
                    searchText = "\(song.title) \(song.artist)"
                    searching = true
                } label: { Label("Search online…", systemImage: "magnifyingglass") }
                if let lyrics, lyrics.hasFileLyrics, lyrics.origin != .file {
                    Button { store.useFileLyrics() } label: { Label("Use the file's lyrics", systemImage: "doc.text") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.body.weight(.semibold)).foregroundStyle(palette.onSurface)
                    .frame(width: 44, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Lyrics options")
        }
        .padding(.horizontal, Spacing.heroGutter)
    }

    private func origin(_ lyrics: SongLyrics?) -> String {
        guard let lyrics, lyrics.text != nil else { return "Lyrics" }
        switch lyrics.origin {
        case .file: return lyrics.parsed.map { if case .plain = $0 { "Lyrics · not synced" } else { "Lyrics" } } ?? "Lyrics"
        case .online, .onlineSaved:
            return "From \(lyrics.provider ?? "online") · \(lyrics.timing?.label ?? "")"
        }
    }

    private func plain(_ lines: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).font(compact ? .headline : .title3.weight(.semibold)).foregroundStyle(palette.onSurface)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? Spacing.lg : Spacing.heroGutter)
            .padding(.vertical, Spacing.lg)
        }
    }

    private func status(_ lookup: LyricsLookup) -> some View {
        let info = statusText(lookup)
        return VStack(spacing: Spacing.md) {
            Spacer()
            if lookup == .searching { ProgressView() }
            Text(info.0).font(.body).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center)
            if lookup != .searching {
                HStack(spacing: Spacing.sm) {
                    if info.1 { Button("Retry") { store.refresh() }.buttonStyle(.bordered) }
                    Button("Search online…") {
                        searchText = "\(song.title) \(song.artist)"
                        searching = true
                    }
                }
                if let url = LyricsWebSearch.url(for: "\(song.title) \(song.artist)") {
                    Link("Search the web", destination: url)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    private func statusText(_ lookup: LyricsLookup) -> (String, Bool) {
        switch lookup {
        case .searching: return ("Looking for lyrics online…", false)
        case .notFound: return ("No matching synced lyrics found. Search online for available versions.", false)
        case .instrumental: return ("This track is instrumental.", false)
        case .offline: return ("Synced lyrics couldn’t be checked while offline.", true)
        case .rateLimited(let at):
            let seconds = max(Int((Double(at) / 1000 - Date().timeIntervalSince1970).rounded()), 1)
            return ("A lyrics service asked to wait (\(seconds) s). Try again shortly.", true)
        case .failed(let reason): return (LyricsFailureMessage.text(reason), true)
        case .idle: return ("No synced lyrics available. Search online for other versions.", false)
        }
    }

    @ViewBuilder
    private func searchResults(_ candidates: [LyricsCandidate]) -> some View {
        if candidates.isEmpty { Text("No results.").foregroundStyle(.secondary) }
        ForEach(candidates) { candidate in
            Button {
                store.choose(candidate)
                searching = false
            } label: {
                VStack(alignment: .leading) {
                    Text(candidate.trackName).foregroundStyle(.primary)
                    Text([candidate.artistName, candidate.provider, candidate.timing.label].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchSheet: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title and artist", text: $searchText)
                        .submitLabel(.search)
                        .onSubmit { store.search(searchText) }
                    Button("Search") { store.search(searchText) }.disabled(searchText.isBlank)
                }
                Section {
                    if let url = LyricsWebSearch.url(for: searchText) {
                        Link(destination: url) { Label("Search the web", systemImage: "safari") }
                    }
                } footer: {
                    Text("Opens in your browser.")
                }
                switch store.current?.search ?? .idle {
                case .idle: EmptyView()
                case .searching: ProgressView()
                case .error(let message): Text(message).foregroundStyle(.secondary)
                case .results(let candidates): searchResults(candidates)
                case .resultsWithNotice(let candidates, let notice):
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    searchResults(candidates)
                }
            }
            .navigationTitle("Search lyrics online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Close") { searching = false } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Time-synced lines that follow playback.
private struct SyncedLyricsView: View {
    let lyrics: Lyrics
    let lines: [LyricLine]
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette
    @Environment(\.lyricsCompact) private var compact
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.playerInMotion) private var playerInMotion
    @Environment(\.visualWorkBudget) private var budget
    @State private var visible = false

    var body: some View {
        let wordTimed = lines.contains { !($0.words?.isEmpty ?? true) }
        let interval = wordTimed && budget.allowsDecorativeMotion ? 0.1 : 0.25
        TimelineView(.animation(minimumInterval: interval,
                                paused: !player.state.isPlaying || !visible || scenePhase != .active || playerInMotion)) { _ in
            let position = player.currentPositionMs()
            let currentLine = lyrics.lineAt(position)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? Spacing.md : Spacing.lg) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Button { player.seek(to: line.timeMs) } label: {
                                lineText(line, index: index, current: currentLine, position: position)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(.horizontal, compact ? Spacing.lg : Spacing.heroGutter)
                    .padding(.top, compact ? Spacing.lg : 120)
                    .padding(.bottom, compact ? 200 : 120)
                }
                .onChange(of: currentLine) { _, line in
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(max(line, 0), anchor: anchor) }
                }
                .onAppear { proxy.scrollTo(max(currentLine, 0), anchor: anchor) }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .reportsScrollVisibility { visible = $0 }
    }

    /// In the card the current line sits nearer the top, leaving most of it for what comes next.
    private var anchor: UnitPoint { compact ? UnitPoint(x: 0.5, y: 0.25) : .center }

    private func wordColor(_ index: Int, sung: Int) -> Color {
        if index < sung { return palette.onSurface }
        return index == sung ? palette.primary : palette.onSurfaceVariant
    }

    private func lineText(_ line: LyricLine, index: Int, current: Int, position: Int64) -> some View {
        let isCurrent = index == current
        let base = Text(line.text.isEmpty ? "♪" : line.text)
        let styled: Text
        if isCurrent, let words = line.words {
            let sung = lyrics.wordAt(line: index, position)
            // Sung words in the line colour, the active word in the accent, upcoming words dimmed.
            styled = words.enumerated().reduce(Text("")) { text, item in
                text + Text(item.element.text).foregroundColor(wordColor(item.offset, sung: sung))
            }
        } else if isCurrent {
            styled = base.foregroundColor(palette.onSurface)
        } else {
            // Other lines fade with their distance from the current one (in the card every line
            // stays readable: only the colour marks the current one).
            let fade = compact ? 1 : max(1 - Double(abs(index - current)) * 0.15, 0.45)
            styled = base.foregroundColor(palette.onSurfaceVariant.opacity(fade))
        }
        return styled
            .font(compact ? .headline : .title2.weight(.bold))
            .scaleEffect(isCurrent || compact ? 1 : 0.96, anchor: .leading)
            .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}
