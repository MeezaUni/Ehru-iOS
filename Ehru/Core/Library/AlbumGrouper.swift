import Foundation

let unknownAlbum = "Unknown Album"

struct AlbumGroup: Equatable, Hashable {
    let id: Int64
    let title: String
    let groupingKey: String
    let albumArtistKey: String?
    let albumArtistText: String?
    let songIds: [Int64]
    let isCompilationTagged: Bool
    let albumArtistInconsistent: Bool
}

/// Layer C. Album identity from album-level raw fields only: title, folder, the Album Artist tag
/// (whole string, never split) and the compilation flag. [AlbumInput] has no track-artist
/// field, so track artists cannot influence grouping.
enum AlbumGrouper {
    private struct Partial {
        let titleKey: String
        let groupingKey: String
        let albumArtistKey: String?
        let members: [AlbumInput]
        let inconsistent: Bool
    }

    private struct DiscTrack: Hashable {
        let disc: Int
        let track: Int
    }

    private static let unknownAlbumKey = CreditText.canonicalKey(unknownAlbum)

    static func group(_ inputs: [AlbumInput], identity: ArtistIdentityResolver) -> [AlbumGroup] {
        let byTitle = inputs.orderedGrouped { input -> StringPair in
            let title = titleKey(input)
            return title == unknownAlbumKey ? StringPair(first: title, second: input.folder) : StringPair(first: title, second: "")
        }.sorted { a, b in
            a.key.first != b.key.first ? utf16Less(a.key.first, b.key.first) : utf16Less(a.key.second, b.key.second)
        }
        return byTitle
            .flatMap { reconcile($0.items, identity: identity) }
            .orderedGrouped { StringPair(first: $0.titleKey, second: $0.groupingKey) }
            .map { merge($0.items) }
            .sorted { $0.id < $1.id }
    }

    private static func titleKey(_ input: AlbumInput) -> String {
        CreditText.canonicalKey(input.album.ifBlank(unknownAlbum))
    }

    private static func reconcile(_ members: [AlbumInput], identity: ArtistIdentityResolver) -> [Partial] {
        let keyOf: (AlbumInput) -> String? = { member in
            member.rawAlbumArtist?.nonBlank.map { identity.canonicalKey(CreditText.canonicalKey($0)) }
        }
        let counts = members.compactMap(keyOf).counts { $0 }
        let majority = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : utf16Less(a.key, b.key)
        }.first?.key
        let collides = counts.count > 1 && members
            .filter { $0.trackNumber > 0 && keyOf($0) != nil }
            .orderedGrouped { DiscTrack(disc: $0.discNumber, track: $0.trackNumber) }
            .contains { slot in Set(slot.items.compactMap(keyOf)).count > 1 }
        let buckets: [(key: String?, items: [AlbumInput])] = collides
            ? members.orderedGrouped { keyOf($0) ?? majority }
            : [(majority, members)]
        let folder = members[0].folder
        return buckets.map { key, bucket in
            let title = titleKey(bucket[0])
            // An untitled album is a folder of loose tracks: never merge it across folders, even by Album Artist.
            let anchor: String
            if title == unknownAlbumKey {
                anchor = "dir:\(folder)"
            } else if let key {
                anchor = "aa:\(key)"
            } else {
                anchor = "title:\(title)"
            }
            return Partial(
                titleKey: title, groupingKey: anchor, albumArtistKey: key, members: bucket,
                inconsistent: !collides && counts.count > 1
            )
        }
    }

    private static func merge(_ parts: [Partial]) -> AlbumGroup {
        let members = parts.flatMap(\.members)
        let first = parts[0]
        let albumArtistTexts = members.compactMap { $0.rawAlbumArtist?.nonBlank?.trimmed }.counts { $0 }
        return AlbumGroup(
            id: IdentityHash.of("album|\(first.titleKey)|\(first.groupingKey)"),
            title: chooseDisplayName(members.map { $0.album.trimmed.ifBlank(unknownAlbum) }.counts { $0 }),
            groupingKey: first.groupingKey,
            albumArtistKey: first.albumArtistKey,
            albumArtistText: albumArtistTexts.isEmpty ? nil : chooseDisplayName(albumArtistTexts),
            songIds: members.map(\.songId).sorted(),
            isCompilationTagged: members.contains { $0.isCompilation },
            albumArtistInconsistent: parts.contains { $0.inconsistent }
        )
    }
}

struct AlbumPresentation: Equatable {
    let displayArtist: String
    let linkedArtistKeys: [String]
    let isCompilation: Bool
}

/// Terminal sink: how an album is shown and which artists it is listed under. Its output is never
/// read by credit resolution or album grouping.
enum AlbumPresenter {
    static let variousArtists = "Various Artists"
    private static let maxCoreArtists = 3

    static func present(
        _ group: AlbumGroup,
        creditsBySong: [Int64: [ResolvedCredit]],
        standaloneKeys: Set<String>,
        identity: ArtistIdentityResolver,
        displayName: (String) -> String
    ) -> AlbumPresentation {
        let counts = group.songIds
            .flatMap { coreKeys(creditsBySong[$0] ?? [], standaloneKeys: standaloneKeys, identity: identity) }
            .counts { $0 }
        let core = counts
            .filter { $0.value * 2 >= group.songIds.count }
            .sorted { a, b in a.value != b.value ? a.value > b.value : utf16Less(a.key, b.key) }
            .map(\.key)
        let dominantCredit = core.isEmpty
            ? dominantUnresolvedCredit(group, creditsBySong: creditsBySong, standaloneKeys: standaloneKeys, identity: identity)
            : nil
        if let tagged = group.albumArtistKey {
            // A tagged Album Artist is shown as written; it is linked only when it names one artist.
            let links = taggedHasIdentity(group, identity: identity) ? [tagged] : []
            return AlbumPresentation(displayArtist: group.albumArtistText ?? displayName(tagged), linkedArtistKeys: links, isCompilation: false)
        }
        if group.isCompilationTagged || core.count > maxCoreArtists {
            return AlbumPresentation(displayArtist: variousArtists, linkedArtistKeys: [], isCompilation: true)
        }
        // Credit text only (no artist identity): shown as written, linked to nobody.
        if let dominantCredit {
            return AlbumPresentation(displayArtist: dominantCredit, linkedArtistKeys: [], isCompilation: false)
        }
        if core.isEmpty {
            return AlbumPresentation(displayArtist: variousArtists, linkedArtistKeys: [], isCompilation: true)
        }
        return AlbumPresentation(displayArtist: joinNames(core.map(displayName)), linkedArtistKeys: core, isCompilation: false)
    }

    private static func taggedHasIdentity(_ group: AlbumGroup, identity: ArtistIdentityResolver) -> Bool {
        guard let text = group.albumArtistText else { return true }
        return CreditText.segmentsOf(text).count <= 1 || identity.isAliased(CreditText.canonicalKey(text))
    }

    /// The unresolved primary credit text on at least half the tracks, when no artist qualifies.
    private static func dominantUnresolvedCredit(
        _ group: AlbumGroup,
        creditsBySong: [Int64: [ResolvedCredit]],
        standaloneKeys: Set<String>,
        identity: ArtistIdentityResolver
    ) -> String? {
        group.songIds
            .flatMap { id in
                Set((creditsBySong[id] ?? [])
                    .filter { $0.role == .primary && !identity.hasIdentity($0) && !standaloneKeys.contains($0.segmentKeys[0]) }
                    .map(\.text))
            }
            .counts { $0 }
            .filter { $0.value * 2 >= group.songIds.count }
            .sorted { a, b in a.value != b.value ? a.value > b.value : utf16Less(a.key, b.key) }
            .first?.key
    }

    private static func coreKeys(
        _ credits: [ResolvedCredit],
        standaloneKeys: Set<String>,
        identity: ArtistIdentityResolver
    ) -> Set<String> {
        Set(credits.filter { $0.role == .primary }.compactMap { credit -> String? in
            let lead = credit.segmentKeys[0]
            if identity.hasIdentity(credit) { return identity.canonicalKey(credit.key) }
            // Counts toward the standalone artist it starts with (raw evidence), never itself.
            if standaloneKeys.contains(lead) { return identity.canonicalKey(lead) }
            return nil
        })
    }

    private static func joinNames(_ names: [String]) -> String {
        names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
    }
}
