import Foundation

/// A song's primary artist id when none of its credits is a resolved artist (no artist row has this id).
let noArtistId: Int64 = 0

/// The derived library for one scan; written to the database by the scanner.
struct LibraryModel: Equatable {
    let songs: [Int64: SongAssignment]
    let credits: [CreditRow]
    let albums: [AlbumRow]
    let albumArtists: [AlbumArtistRow]
    let artists: [ArtistRow]
    let unverifiedSegments: [UnverifiedSegmentRow]
}

struct SongAssignment: Equatable {
    let albumId: Int64
    let primaryArtistId: Int64
}

struct CreditRow: Equatable {
    let songId: Int64
    let artistId: Int64
    let role: CreditRole
    let position: Int
    let creditText: String
    let isUnresolved: Bool
}

struct AlbumRow: Equatable {
    let id: Int64
    let title: String
    let displayArtist: String
    let leadArtistId: Int64
    let songIds: [Int64]
    let isCompilation: Bool
    let albumArtistInconsistent: Bool
    let groupingKey: String
}

struct AlbumArtistRow: Equatable {
    let albumId: Int64
    let artistId: Int64
    let position: Int
}

struct ArtistRow: Equatable {
    let id: Int64
    let key: String
    let name: String
    let songCount: Int
    let albumCount: Int
    let isUnresolved: Bool
}

/// [artistId] is the hash of the unresolved credit text (a credit id), never an artist row.
struct UnverifiedSegmentRow: Equatable {
    let songId: Int64
    let artistId: Int64
    let segmentKey: String
    let segmentIndex: Int
}

/// Builds the derived library in a fixed order:
/// raw rows → evidence → credits (A) → identity (B) → album groups (C, artist-free) → presentation.
///
/// Credit text is not artist identity: only credits with an identity (resolved, or named by
/// explicit alias evidence) become artist rows and song–artist links.
enum LibraryModelBuilder {
    static func build(_ tracks: [RawTrack], aliases: [String: String]) -> LibraryModel {
        let ordered = tracks.sorted { $0.songId < $1.songId }
        let evidence = EvidenceIndex.build(ordered)
        // Database aliases are applied on top of the individually approved manual ones.
        let identity = ArtistIdentityResolver(
            aliases: ManualArtistAliases.aliasKeys.merging(aliases) { _, new in new },
            canonicalNames: ManualArtistAliases.artistNames
        )
        let resolver = CreditResolver(evidence: evidence)
        let credits: [(songId: Int64, credits: [ResolvedCredit])] = ordered.map { ($0.songId, resolver.resolve($0)) }
        let creditsBySong = Dictionary(credits.map { ($0.songId, $0.credits) }, uniquingKeysWith: { first, _ in first })
        let identityCredits = credits.map { ($0.songId, $0.credits.filter(identity.hasIdentity)) }
        let groups = AlbumGrouper.group(ordered.map { $0.toAlbumInput() }, identity: identity)
        let names = displayNames(identityCredits.flatMap { $0.1 }, groups: groups, identity: identity)
        let presentations = groups.map { group in
            (group, AlbumPresenter.present(
                group, creditsBySong: creditsBySong, standaloneKeys: evidence.standaloneKeys, identity: identity
            ) { names[$0] ?? $0 })
        }
        let creditRows = creditRows(identityCredits, identity: identity)
        let albumArtists = presentations.flatMap { group, presentation in
            presentation.linkedArtistKeys.enumerated().map { i, key in
                AlbumArtistRow(albumId: group.id, artistId: identity.idOf(key), position: i)
            }
        }
        return LibraryModel(
            songs: songAssignments(groups, credits: identityCredits, identity: identity),
            credits: creditRows,
            albums: presentations.map { albumRow($0, $1, identity: identity) },
            albumArtists: albumArtists,
            artists: artistRows(creditRows, albumArtists: albumArtists, credits: identityCredits, names: names, identity: identity),
            unverifiedSegments: unverified(credits, standaloneKeys: evidence.standaloneKeys, identity: identity)
        )
    }

    private static func displayNames(
        _ credits: [ResolvedCredit],
        groups: [AlbumGroup],
        identity: ArtistIdentityResolver
    ) -> [String: String] {
        var variants: [String: [String: Int]] = [:]
        for credit in credits {
            variants[identity.canonicalKey(credit.key), default: [:]][credit.text, default: 0] += 1
        }
        for group in groups {
            guard let key = group.albumArtistKey, let text = group.albumArtistText else { continue }
            variants[key, default: [:]][text, default: 0] += 1
        }
        return variants.reduce(into: [:]) { out, entry in
            out[entry.key] = identity.approvedName(entry.key) ?? chooseDisplayName(entry.value)
        }
    }

    private static func creditRows(
        _ credits: [(Int64, [ResolvedCredit])],
        identity: ArtistIdentityResolver
    ) -> [CreditRow] {
        credits.flatMap { songId, list in
            list.distinct { identity.canonicalKey($0.key) }.map {
                // Every credit here has an identity, so none is stored as unresolved.
                CreditRow(
                    songId: songId, artistId: identity.idOf($0.key), role: $0.role, position: $0.position,
                    creditText: $0.text, isUnresolved: false
                )
            }
        }
    }

    private static func songAssignments(
        _ groups: [AlbumGroup],
        credits: [(Int64, [ResolvedCredit])],
        identity: ArtistIdentityResolver
    ) -> [Int64: SongAssignment] {
        var albumOf: [Int64: Int64] = [:]
        for group in groups {
            for songId in group.songIds { albumOf[songId] = group.id }
        }
        var out: [Int64: SongAssignment] = [:]
        for (songId, list) in credits {
            let lead = list.first { $0.role == .primary } ?? list.first
            out[songId] = SongAssignment(albumId: albumOf[songId]!, primaryArtistId: lead.map { identity.idOf($0.key) } ?? noArtistId)
        }
        return out
    }

    private static func albumRow(_ group: AlbumGroup, _ presentation: AlbumPresentation, identity: ArtistIdentityResolver) -> AlbumRow {
        AlbumRow(
            id: group.id,
            title: group.title,
            displayArtist: presentation.displayArtist,
            leadArtistId: presentation.linkedArtistKeys.first.map(identity.idOf) ?? noArtistId,
            songIds: group.songIds,
            isCompilation: presentation.isCompilation,
            albumArtistInconsistent: group.albumArtistInconsistent,
            groupingKey: group.groupingKey
        )
    }

    private static func artistRows(
        _ creditRows: [CreditRow],
        albumArtists: [AlbumArtistRow],
        credits: [(Int64, [ResolvedCredit])],
        names: [String: String],
        identity: ArtistIdentityResolver
    ) -> [ArtistRow] {
        var keyOfId: [Int64: String] = [:]
        for credit in credits.flatMap({ $0.1 }) {
            keyOfId[identity.idOf(credit.key)] = identity.canonicalKey(credit.key)
        }
        for key in names.keys where keyOfId[identity.idOf(key)] == nil {
            keyOfId[identity.idOf(key)] = key
        }
        let songCounts = Dictionary(grouping: creditRows, by: \.artistId).mapValues { Set($0.map(\.songId)).count }
        let albumCounts = Dictionary(grouping: albumArtists, by: \.artistId).mapValues { Set($0.map(\.albumId)).count }
        return Set(songCounts.keys).union(albumCounts.keys).sorted().map { id in
            let key = keyOfId[id]!
            return ArtistRow(
                id: id, key: key, name: names[key] ?? key, songCount: songCounts[id] ?? 0,
                albumCount: albumCounts[id] ?? 0, isUnresolved: false
            )
        }
    }

    private static func unverified(
        _ credits: [(songId: Int64, credits: [ResolvedCredit])],
        standaloneKeys: Set<String>,
        identity: ArtistIdentityResolver
    ) -> [UnverifiedSegmentRow] {
        credits.flatMap { songId, list in
            // Display-only: credits without an identity, linked to the standalone artists they contain.
            list.filter { !identity.hasIdentity($0) }.flatMap { credit in
                credit.segmentKeys.enumerated()
                    .filter { standaloneKeys.contains($0.element) }
                    .map { i, key in
                        UnverifiedSegmentRow(songId: songId, artistId: identity.idOf(credit.key), segmentKey: key, segmentIndex: i)
                    }
            }
        }
    }
}
