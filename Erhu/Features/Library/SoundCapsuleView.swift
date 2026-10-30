import SwiftUI

/// Sound Capsule: one month of listening (the current month first): the top song, plays, minutes,
/// the longest listening streak, and the top songs, albums and artists.
struct SoundCapsuleView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette
    @State private var month = ListeningMonth.current
    @State private var months: [String] = []
    @State private var capsule: SoundCapsule?

    var body: some View {
        let all = Array(Set(months + [ListeningMonth.current])).sorted()
        let previous = all.last { $0 < month }
        let next = all.first { $0 > month }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { if let previous { month = previous } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(previous == nil)
                        .accessibilityLabel("Previous month")
                    Spacer()
                    VStack(spacing: 2) {
                        Text("YOUR MONTH").font(.caption.weight(.semibold)).foregroundStyle(palette.onSurfaceVariant)
                        Text(ListeningMonth.title(month)).font(.title2.weight(.bold))
                    }
                    Spacer()
                    Button { if let next { month = next } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(next == nil)
                        .accessibilityLabel("Next month")
                }
                .padding(.horizontal, Spacing.sm)
                if let capsule {
                    if capsule.isEmpty {
                        VStack(spacing: Spacing.sm) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 40)).foregroundStyle(palette.primary)
                            Text("Nothing played in \(ListeningMonth.name(month)) yet").font(.headline).multilineTextAlignment(.center)
                            Text("Songs you play this month show up here: your top songs, albums and artists.")
                                .font(.subheadline).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.xxl)
                    } else {
                        content(capsule)
                    }
                }
            }
            .padding(.bottom, Spacing.lg)
        }
        .navigationTitle("Sound Capsule")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(month)|\(library.songs.count)|\(library.recentAlbums.map(\.id))") { load() }
    }

    private func load() {
        months = (try? library.database.listeningMonths()) ?? []
        capsule = try? library.database.capsule(month: month)
    }

    @ViewBuilder
    private func content(_ capsule: SoundCapsule) -> some View {
        let songs = capsule.topSongs.map(\.song)
        if let top = capsule.topSongs.first {
            Button { actions.play(songs, startIndex: 0) } label: {
                ZStack(alignment: .bottomLeading) {
                    SongArtworkView(song: top.song, maxPixels: 900)
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.7), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your top song").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                        Text(top.song.title).font(.title2.weight(.bold)).foregroundStyle(.white).lineLimit(2)
                        Text("\(top.song.artist) · \(playsLabel(top.plays))").font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    .padding(Spacing.lg)
                }
                .aspectRatio(1.4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            .accessibilityHint("Plays the month's top songs")
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.sm)
        }
        let minutes = capsule.listenedMs / 60_000
        HStack(spacing: Spacing.sm) {
            summary("\(capsule.totalPlays)", capsule.totalPlays == 1 ? "play" : "plays")
            summary("\(minutes)", minutes == 1 ? "minute" : "minutes")
            summary("\(capsule.longestStreakDays)", "day streak")
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.sm)
        if !capsule.topSongs.isEmpty {
            title("Top songs")
            ForEach(Array(capsule.topSongs.enumerated()), id: \.element.song.id) { index, ranked in
                Button { actions.play(songs, startIndex: index) } label: {
                    HStack(spacing: Spacing.sm) {
                        Text("\(index + 1)").font(.title3.weight(.bold)).foregroundStyle(palette.primary).frame(width: 28)
                        SongArtworkView(song: ranked.song, maxPixels: 168)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ranked.song.title).font(.body.weight(.bold)).lineLimit(1)
                            Text(ranked.song.artist).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                        }
                        Spacer(minLength: Spacing.sm)
                        Text(playsLabel(ranked.plays)).font(.caption).foregroundStyle(palette.onSurfaceVariant)
                    }
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.vertical, Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        if !capsule.topAlbums.isEmpty {
            title("Top albums")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Spacing.md) {
                    ForEach(Array(capsule.topAlbums.enumerated()), id: \.element.album.id) { index, ranked in
                        Button { router.open(.album(ranked.album.id)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                AlbumArtworkView(albumId: ranked.album.id)
                                    .frame(width: 148, height: 148)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                                    .overlay(alignment: .topLeading) { badge(index + 1).padding(Spacing.sm) }
                                Text(ranked.album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(ranked.album.artist).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                                Text(playsLabel(ranked.plays)).font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                            }
                            .frame(width: 148)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.gutter)
            }
        }
        if !capsule.topArtists.isEmpty {
            title("Top artists")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Spacing.md) {
                    ForEach(Array(capsule.topArtists.enumerated()), id: \.element.artist.id) { index, ranked in
                        Button { router.open(.artist(ranked.artist.id)) } label: {
                            VStack(spacing: 2) {
                                ArtistArtworkView(artist: ranked.artist, fontSize: 36)
                                    .frame(width: 112, height: 112)
                                    .clipShape(Circle())
                                    .overlay(alignment: .topLeading) { badge(index + 1) }
                                Text(ranked.artist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(playsLabel(ranked.plays)).font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                            }
                            .frame(width: 112)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.gutter)
            }
        }
    }

    private func summary(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(palette.surfaceVariant.opacity(0.5)))
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold))
            .padding(.horizontal, Spacing.gutter)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.sm)
    }

    private func badge(_ rank: Int) -> some View {
        Text("\(rank)").font(.subheadline.weight(.bold)).foregroundStyle(palette.onPrimary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(palette.primary))
    }

    private func playsLabel(_ plays: Int) -> String { plays == 1 ? "1 play" : "\(plays) plays" }
}

/// Listening months as stored ("YYYY-MM", local calendar).
enum ListeningMonth {
    static var current: String { LibraryDatabase.keys(Date(), calendar: .current).month }

    private static func date(_ month: String) -> Date? {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let number = Int(parts[1]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: number, day: 1))
    }

    /// "October 2026".
    static func title(_ month: String) -> String {
        guard let date = date(month) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// "October".
    static func name(_ month: String) -> String {
        guard let date = date(month) else { return month }
        return date.formatted(.dateTime.month(.wide))
    }
}
