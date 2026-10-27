import Foundation

/// One song's vector and the hash of the description it was embedded from.
struct IndexedSong {
    let songId: Int64
    let textHash: Int64
    let vector: [Float]
}

/// VYBE's on-disk vector cache, in the Android app's format: a header (magic, version, dimension,
/// model id) then one big-endian record per embedded description (song id, text hash, vector),
/// appended as indexing goes so an interrupted run keeps what it finished; a song's last record wins.
///
/// - Only derived data is stored: song id, a hash of the embedded text, the vector. No text.
/// - A file written for another model or vector size is ignored and replaced.
/// - Reading maps the file instead of loading it, so a large library is fine.
/// - [compact] rewrites it with live records only.
///
/// Not thread-safe: one owner (the VYBE engine) serialises access.
final class VybeIndexFile {
    private static let magic = Array("VYBEIDX1".utf8)
    private static let formatVersion: UInt32 = 1

    let url: URL
    private let modelId: String
    private let dimension: Int
    private let recordBytes: Int

    init(url: URL, modelId: String, dimension: Int) {
        precondition(dimension > 0, "dimension must be positive")
        self.url = url
        self.modelId = modelId
        self.dimension = dimension
        recordBytes = 16 + 4 * dimension
    }

    /// Live entries: song id -> hash of its embedded text. Empty when missing or incompatible.
    func entries() -> [Int64: Int64] {
        var live: [Int64: Int64] = [:]
        forEachRecord(withVectors: false) { _, id, hash, _ in live[id] = hash }
        return live
    }

    /// Record number of each [live] song's last record whose hash is current.
    private func latestRecords(_ live: [Int64: Int64]) -> [Int64: Int] {
        var latest: [Int64: Int] = [:]
        forEachRecord(withVectors: false) { index, id, hash, _ in if live[id] == hash { latest[id] = index } }
        return latest
    }

    /// Appends [songs]; starts a new file when there is none or it belongs to another model.
    func append(_ songs: [IndexedSong]) throws {
        if songs.isEmpty { return }
        var bytes = Data()
        let fresh = !isCompatible
        if fresh { bytes.append(header()) }
        for song in songs { bytes.append(record(song)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fresh {
            try bytes.write(to: url)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        }
    }

    /// The current vectors of the [wanted] songs among [live] (id -> hash).
    func vectorsOf(live: [Int64: Int64], wanted: Set<Int64>) -> [Int64: [Float]] {
        if wanted.isEmpty { return [:] }
        let current = latestRecords(live.filter { wanted.contains($0.key) })
        var found: [Int64: [Float]] = [:]
        forEachRecord(withVectors: true) { index, id, _, vector in if current[id] == index { found[id] = vector } }
        return found
    }

    /// The stored vector of [songId] (its last record), or nil.
    func vectorOf(_ songId: Int64) -> [Float]? {
        var found: [Float]?
        forEachRecord(withVectors: true) { _, id, _, vector in if id == songId { found = vector } }
        return found
    }

    /// The [limit] best songs by [score] (nil leaves a song out), best first, equal scores by song
    /// id. Only songs in [live] count, with their current vector.
    func rank(live: [Int64: Int64], limit: Int, score: (Int64, [Float]) -> Float?) -> [VybeMatch] {
        if limit <= 0 { return [] }
        let current = latestRecords(live)
        var matches: [VybeMatch] = []
        forEachRecord(withVectors: true) { index, id, _, vector in
            guard current[id] == index, let value = score(id, vector), value.isFinite else { return }
            matches.append(VybeMatch(songId: id, score: value))
        }
        return Array(matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.songId < $1.songId }.prefix(limit))
    }

    /// Rewrites the file with the [keep] songs' current records only.
    func compact(keep: [Int64: Int64]) throws {
        guard isCompatible else { return }
        let current = latestRecords(keep)
        var bytes = header()
        forEachRecord(withVectors: true) { index, id, hash, vector in
            if current[id] == index { bytes.append(record(IndexedSong(songId: id, textHash: hash, vector: vector))) }
        }
        try bytes.write(to: url, options: .atomic)
    }

    /// Number of records on disk (live or superseded): for deciding when to [compact].
    func recordCount() -> Int {
        guard isCompatible, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return 0 }
        return (size - header().count) / recordBytes
    }

    var isCompatible: Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return Self.readHeader(data, modelId: modelId) == dimension
    }

    /// The vector size [url] was written with, when it is an index of [modelId]: lets the stored
    /// vectors be read without loading the model. Nil when missing or incompatible.
    static func storedDimension(_ url: URL, modelId: String) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return readHeader(data, modelId: modelId)
    }

    private func header() -> Data {
        var data = Data(Self.magic)
        data.appendBE(Self.formatVersion)
        data.appendBE(UInt32(dimension))
        let id = Array(modelId.utf8)
        data.appendBE(UInt16(id.count))
        data.append(contentsOf: id)
        return data
    }

    private func record(_ song: IndexedSong) -> Data {
        precondition(song.vector.count == dimension, "vector size \(song.vector.count) != \(dimension)")
        var data = Data(capacity: recordBytes)
        data.appendBE(UInt64(bitPattern: song.songId))
        data.appendBE(UInt64(bitPattern: song.textHash))
        for value in song.vector { data.appendBE(value.bitPattern) }
        return data
    }

    /// The dimension in the header when it is this format and model; nil otherwise.
    private static func readHeader(_ data: Data, modelId: String) -> Int? {
        headerLength(data, modelId: modelId).map { _ in Int(data.uint32BE(magic.count + 4)) }
    }

    /// Bytes of a valid header for [modelId], or nil.
    private static func headerLength(_ data: Data, modelId: String) -> Int? {
        let fixed = magic.count + 4 + 4 + 2
        guard data.count >= fixed, Array(data.prefix(magic.count)) == magic,
              data.uint32BE(magic.count) == formatVersion, data.uint32BE(magic.count + 4) > 0 else { return nil }
        let idLength = Int(data.uint16BE(magic.count + 8))
        guard data.count >= fixed + idLength, data.slice(fixed, idLength) == Data(modelId.utf8) else { return nil }
        return fixed + idLength
    }

    private func forEachRecord(withVectors: Bool, _ action: (Int, Int64, Int64, [Float]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let start = Self.headerLength(data, modelId: modelId), Int(data.uint32BE(Self.magic.count + 4)) == dimension
        else { return }
        let recordBytes = recordBytes
        let dimension = dimension
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = start
            var index = 0
            // A record cut short by an interrupted write is ignored: everything before it stands.
            while offset + recordBytes <= raw.count {
                let id = Int64(bitPattern: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
                let hash = Int64(bitPattern: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)))
                var vector: [Float] = []
                if withVectors {
                    vector.reserveCapacity(dimension)
                    for i in 0..<dimension {
                        let bits = UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset + 16 + 4 * i, as: UInt32.self))
                        vector.append(Float(bitPattern: bits))
                    }
                }
                action(index, id, hash, vector)
                index += 1
                offset += recordBytes
            }
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
