import Foundation

/// Deterministic 64-bit FNV-1a over UTF-16 code units: the same ids the Android app gives.
enum IdentityHash {
    private static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let prime: UInt64 = 1_099_511_628_211

    static func of(_ key: String) -> Int64 {
        var hash = offsetBasis
        for unit in key.utf16 {
            hash ^= UInt64(unit)
            hash = hash &* prime
        }
        return Int64(bitPattern: hash)
    }
}

/// Layer B. An artist is its canonical key; [aliases] (alias key → canonical key) come only from
/// explicit manual/external evidence. No fuzzy matching, no chains.
struct ArtistIdentityResolver {
    let aliases: [String: String]
    var canonicalNames: [String: String] = [:]

    func canonicalKey(_ creditKey: String) -> String { aliases[creditKey] ?? creditKey }

    func idOf(_ creditKey: String) -> Int64 { IdentityHash.of(canonicalKey(creditKey)) }

    /// True when explicit evidence names the artist behind this credit text.
    func isAliased(_ creditKey: String) -> Bool { aliases[creditKey] != nil }

    func approvedName(_ canonicalKey: String) -> String? { canonicalNames[canonicalKey] }

    /// A resolved credit denotes an artist; an unresolved one only through explicit alias evidence.
    func hasIdentity(_ credit: ResolvedCredit) -> Bool { !credit.isUnresolved || isAliased(credit.key) }
}

/// The most frequent spelling; ties broken by Kotlin string order.
func chooseDisplayName(_ variants: [String: Int]) -> String {
    variants.sorted { a, b in
        a.value != b.value ? a.value > b.value : utf16Less(a.key, b.key)
    }.first!.key
}

/// Explicitly approved manual identity evidence: each entry maps one exact credit text to one
/// artist and was approved individually. Database aliases are applied on top of these.
enum ManualArtistAliases {
    private static let approved: [(creditText: String, artistName: String)] = [
        // Approved 2026-10-04: the files' tag writes this artist as "Tyler/ The Creator".
        ("Tyler/ The Creator", "Tyler, The Creator"),
    ]

    /// Alias credit key → canonical artist key.
    static let aliasKeys: [String: String] = Dictionary(
        uniqueKeysWithValues: approved.map { (CreditText.canonicalKey($0.creditText), CreditText.canonicalKey($0.artistName)) }
    )

    /// Canonical artist key → the artist's approved display name.
    static let artistNames: [String: String] = Dictionary(
        uniqueKeysWithValues: approved.map { (CreditText.canonicalKey($0.artistName), $0.artistName) }
    )
}

enum PrimaryArtistExtractor {
    static func extractPrimaryArtist(_ rawArtist: String?) -> String? {
        guard let rawArtist, !rawArtist.isBlank,
              rawArtist.caseInsensitiveCompare("Unknown Artist") != .orderedSame
        else { return nil }
        let firstRun = CreditText.runs(rawArtist).first?.raw ?? rawArtist
        let firstSegment = CreditText.segmentsOf(firstRun).first?.text.trimmed
        if let firstSegment, !firstSegment.isBlank, firstSegment.caseInsensitiveCompare("Unknown Artist") != .orderedSame {
            return firstSegment
        }
        return rawArtist.trimmed
    }
}
