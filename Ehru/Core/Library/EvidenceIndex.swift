import Foundation

/// Boundary evidence built ONCE from raw rows; nothing downstream can feed back into it.
///
/// - Rule 1: segments a and b are independent when a appears in some raw credit without b AND
///   b appears in some raw credit without a.
/// - Rule 2: a title marker block (feat./ft./featuring/with) that equals the tail of the track's
///   primary credit text proves the boundary before that tail. The block is compared whole.
/// - Rule 3: a proven boundary applies wherever the same raw segment run appears. Only the
///   boundary propagates; the marker's role stays on its own track.
final class EvidenceIndex {
    static let unknownArtistKey = "unknown artist"

    private struct RoleKey: Hashable {
        let songId: Int64
        let boundary: Int
    }

    private let observationsBySegment: [String: [Set<String>]]
    private let markerRuns: [[String]: Set<Int>]
    private let ownMarkerRoles: [RoleKey: CreditRole]
    let standaloneKeys: Set<String>

    private init(
        observationsBySegment: [String: [Set<String>]],
        markerRuns: [[String]: Set<Int>],
        ownMarkerRoles: [RoleKey: CreditRole],
        standaloneKeys: Set<String>
    ) {
        self.observationsBySegment = observationsBySegment
        self.markerRuns = markerRuns
        self.ownMarkerRoles = ownMarkerRoles
        self.standaloneKeys = standaloneKeys
    }

    func independent(_ a: String, _ b: String) -> Bool {
        (observationsBySegment[a] ?? []).contains { !$0.contains(b) }
            && (observationsBySegment[b] ?? []).contains { !$0.contains(a) }
    }

    func propagatedBoundaries(_ keys: [String]) -> Set<Int> {
        var out = Set<Int>()
        for (run, boundaries) in markerRuns where run.count <= keys.count {
            for start in 0...(keys.count - run.count) where Array(keys[start..<(start + run.count)]) == run {
                boundaries.forEach { out.insert(start + $0) }
            }
        }
        return out
    }

    func ownMarkerRole(songId: Int64, boundary: Int) -> CreditRole? {
        ownMarkerRoles[RoleKey(songId: songId, boundary: boundary)]
    }

    private static let titleMarker = Regex16(
        "[(\\[][ \\t\\n\\x0B\\f\\r]*(feat\\.?|ft\\.|featuring|with)[ \\t\\n\\x0B\\f\\r]+([^)\\]]+)[)\\]]"
            + "|[ \\t\\n\\x0B\\f\\r](feat\\.?|ft\\.|featuring)[ \\t\\n\\x0B\\f\\r]+(.+)$",
        ignoreCase: true
    )

    static func build(_ tracks: [RawTrack]) -> EvidenceIndex {
        var bySegment: [String: [Set<String>]] = [:]
        for raw in tracks.flatMap({ [$0.rawArtist, $0.rawAlbumArtist].compactMap { $0 } }) {
            let observation = Set(CreditText.runs(raw).flatMap { run in run.segments.map(\.key) })
            if observation.isEmpty { continue }
            for key in observation {
                bySegment[key, default: []].append(observation)
            }
        }

        var markerRuns: [[String]: Set<Int>] = [:]
        var ownRoles: [RoleKey: CreditRole] = [:]
        for track in tracks {
            guard let run = CreditText.runs(track.rawArtist).first(where: { !$0.featured }) else { continue }
            for (word, block) in titleMarkers(track.title) {
                guard let boundary = markerBoundary(run, block) else { continue }
                markerRuns[run.segments.map(\.key), default: []].insert(boundary)
                ownRoles[RoleKey(songId: track.songId, boundary: boundary)] =
                    word.caseInsensitiveCompare("with") == .orderedSame ? .primary : .featured
            }
        }

        let standalone = Set(tracks.compactMap { track -> String? in
            let runs = CreditText.runs(track.rawArtist)
            guard runs.count == 1, runs[0].segments.count == 1 else { return nil }
            return runs[0].segments[0].key
        }.filter { $0 != unknownArtistKey })

        return EvidenceIndex(
            observationsBySegment: bySegment, markerRuns: markerRuns,
            ownMarkerRoles: ownRoles, standaloneKeys: standalone
        )
    }

    /// (marker word, block) for each marker: groups 1-2 are "(feat. X)", 3-4 a trailing " feat. X".
    private static func titleMarkers(_ title: String) -> [(String, String)] {
        titleMarker.matches(in: title).map { match in
            let bracketBlock = match.group(2, in: title)
            return bracketBlock.isEmpty
                ? (match.group(3, in: title), match.group(4, in: title))
                : (match.group(1, in: title), bracketBlock)
        }
    }

    /// Boundary b (≥ 1) such that the run's raw text from segment b to the end equals [block] as a whole.
    private static func markerBoundary(_ run: CreditRun, _ block: String) -> Int? {
        let target = CreditText.blockKey(block)
        guard run.segments.count > 1 else { return nil }
        return (1..<run.segments.count).first { b in
            CreditText.blockKey(run.raw.substring16(from: run.segments[b].start)) == target
        }
    }
}
