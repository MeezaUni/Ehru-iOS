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
    @State private var colors = LyricsColors(.fallback)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        LyricsPanelContent(song: song, onExpand: onExpand)
            .environment(\.palette, palette.lyrics(colors))
            .environment(\.lyricsColors, colors)
            .environment(\.lyricsCompact, onExpand != nil)
            .background { if onExpand != nil { CardSurface(colors: colors, shape: shape) } }
            .clipShape(shape)
            .task(id: song.url) {
                // The previous colours stay while the next artwork is sampled, then cross-fade.
                let next = LyricsColors(await LyricsPaletteCache.shared.palette(for: song.url))
                withAnimation(.easeInOut(duration: 0.6)) { colors = next }
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
        .sheet(isPresented: $searching, onDismiss: { store.closeSearch() }) { searchSheet }
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
        case .notFound: "No lyrics found · tap to search"
        case .instrumental: "Instrumental"
        case .offline: "Offline · lyrics will be looked up when you're back online"
        case .rateLimited: "Lyrics lookup paused for a moment"
        case .failed: "Lyrics couldn't be loaded · tap to retry"
        case .needsChoice: "Several lyrics found · tap to choose"
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

    @ViewBuilder
    private func status(_ lookup: LyricsLookup) -> some View {
        if case .needsChoice(let candidates) = lookup {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Is it one of these?").font(.headline)
                    ForEach(candidates) { candidate in candidateRow(candidate) }
                    Button("Search online…") {
                        searchText = "\(song.title) \(song.artist)"
                        searching = true
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, Spacing.heroGutter)
            }
        } else {
            let info = statusText(lookup)
            let message = info.0
            let retry = info.1
            VStack(spacing: Spacing.md) {
                Spacer()
                if lookup == .searching { ProgressView() }
                Text(message).font(.body).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center)
                if lookup != .searching {
                    HStack(spacing: Spacing.sm) {
                        if retry { Button("Retry") { store.refresh() }.buttonStyle(.bordered) }
                        Button("Search online…") {
                            searchText = "\(song.title) \(song.artist)"
                            searching = true
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }

    private func statusText(_ lookup: LyricsLookup) -> (String, Bool) {
        switch lookup {
        case .searching: return ("Looking for lyrics online…", false)
        case .notFound: return ("No lyrics found for this song.", false)
        case .instrumental: return ("This track is instrumental.", false)
        case .offline: return ("You are offline. Lyrics will be looked up when you are back online.", true)
        case .rateLimited(let at):
            let seconds = max(Int((Double(at) / 1000 - Date().timeIntervalSince1970).rounded()), 1)
            return ("LRCLIB asked to wait (\(seconds) s). Try again shortly.", true)
        case .failed(let reason): return ("Could not look up lyrics (\(reason)).", true)
        case .idle, .needsChoice: return ("This file has no embedded lyrics.", false)
        }
    }

    private func candidateRow(_ candidate: LyricsCandidate) -> some View {
        Button { store.choose(candidate) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.trackName).font(.body.weight(.semibold)).foregroundStyle(palette.onSurface).lineLimit(1)
                let details = [candidate.artistName, candidate.albumName, candidate.durationSec.map { formatDuration(Int64($0 * 1000)) },
                               candidate.timing.label].compactMap { $0 }.filter { !$0.isBlank }
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(palette.surfaceVariant.opacity(0.5)))
        }
        .buttonStyle(.plain)
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
                switch store.current?.search ?? .idle {
                case .idle: EmptyView()
                case .searching: ProgressView()
                case .error(let message): Text(message).foregroundStyle(.secondary)
                case .results(let candidates):
                    if candidates.isEmpty { Text("No results.").foregroundStyle(.secondary) }
                    ForEach(candidates) { candidate in
                        Button {
                            store.choose(candidate)
                            searching = false
                        } label: {
                            VStack(alignment: .leading) {
                                Text(candidate.trackName).foregroundStyle(.primary)
                                Text([candidate.artistName, candidate.timing.label].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let position = player.currentPositionMs()
            let currentLine = lyrics.lineAt(position)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? Spacing.md : Spacing.lg) {
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
