import Foundation

let unknownArtist = "Unknown Artist"

/// One credited unit on a track. [isUnresolved]: the unit spans a candidate boundary that had no evidence.
struct ResolvedCredit: Equatable {
    var text: String
    var key: String
    var role: CreditRole
    var position: Int
    var isUnresolved: Bool
    var segmentKeys: [String]
}

/// Layer A. Splits a credit only at boundaries the evidence proves; otherwise keeps the original text.
struct CreditResolver {
    let evidence: EvidenceIndex

    func resolve(_ track: RawTrack) -> [ResolvedCredit] {
        let runs = CreditText.runs(track.rawArtist)
        let credits = runs.isEmpty || CreditText.canonicalKey(track.rawArtist) == EvidenceIndex.unknownArtistKey
            ? [unknown()]
            : runs.flatMap { unitsOf(songId: track.songId, run: $0) }
        return credits.distinct(by: \.key).enumerated().map { index, credit in
            var positioned = credit
            positioned.position = index
            return positioned
        }
    }

    private func unitsOf(songId: Int64, run: CreditRun) -> [ResolvedCredit] {
        let keys = run.segments.map(\.key)
        let proven = evidence.propagatedBoundaries(keys)
        var units: [ResolvedCredit] = []
        var first = 0
        var role: CreditRole = run.featured ? .featured : .primary
        for i in 1...keys.count {
            let boundary = i == keys.count || proven.contains(i) || evidence.independent(keys[i - 1], keys[i])
            if !boundary { continue }
            units.append(unit(run, from: first, to: i, role: role))
            if i < keys.count, !run.featured {
                role = evidence.ownMarkerRole(songId: songId, boundary: i) ?? role
            }
            first = i
        }
        return units
    }

    private func unit(_ run: CreditRun, from: Int, to: Int, role: CreditRole) -> ResolvedCredit {
        let text = run.raw.substring16(run.segments[from].start, run.segments[to - 1].end)
        return ResolvedCredit(
            text: text, key: CreditText.canonicalKey(text), role: role, position: 0,
            isUnresolved: to - from > 1, segmentKeys: run.segments[from..<to].map(\.key)
        )
    }

    private func unknown() -> ResolvedCredit {
        ResolvedCredit(
            text: unknownArtist, key: EvidenceIndex.unknownArtistKey, role: .primary, position: 0,
            isUnresolved: false, segmentKeys: [EvidenceIndex.unknownArtistKey]
        )
    }
}
