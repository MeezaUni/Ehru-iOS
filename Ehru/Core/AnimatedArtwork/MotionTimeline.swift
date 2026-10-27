import Foundation

/// Apple HLS fragments can begin at 10 seconds. Rebase single-track decode times to zero
/// without changing frame data; otherwise a downloaded cover can start with a long blank wait.
enum MotionTimeline {
    private struct Box { let type: String; let content: UInt64; let end: UInt64 }
    private struct Time { let position: UInt64; let wide: Bool; let value: UInt64; let track: UInt32 }

    @discardableResult
    static func startAtZero(_ url: URL) throws -> Bool {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        func read(_ count: Int, at offset: UInt64) throws -> Data {
            try file.seek(toOffset: offset)
            return try file.read(upToCount: count) ?? Data()
        }
        func boxes(from start: UInt64, to end: UInt64) throws -> [Box] {
            var position = start
            var result: [Box] = []
            while position < end {
                guard end - position >= 8 else { throw MotionArtworkError("Truncated video box.") }
                let head = try read(Int(min(16, end - position)), at: position)
                var length = UInt64(head.uint32BE(0))
                let header: UInt64 = length == 1 ? 16 : 8
                if length == 1 { length = head.uint64BE(8) }
                if length == 0 { length = end - position }
                guard length >= header, length <= end - position else { throw MotionArtworkError("Invalid video box.") }
                result.append(Box(type: head.ascii(4, 4), content: position + header, end: position + length))
                position += length
            }
            return result
        }
        var times: [Time] = []
        for fragment in try boxes(from: 0, to: size) where fragment.type == "moof" {
            for track in try boxes(from: fragment.content, to: fragment.end) where track.type == "traf" {
                var id: UInt32?
                var timing: (UInt64, Bool, UInt64)?
                for box in try boxes(from: track.content, to: track.end) {
                    if box.type == "tfhd" {
                        guard box.end - box.content >= 8 else { throw MotionArtworkError("Invalid video track header.") }
                        id = try read(4, at: box.content + 4).uint32BE(0)
                    }
                    if box.type == "tfdt" {
                        let head = try read(Int(min(12, box.end - box.content)), at: box.content)
                        guard head.count >= 8, head.byte(0) <= 1 else { throw MotionArtworkError("Invalid video decode time.") }
                        let wide = head.byte(0) == 1
                        guard !wide || head.count >= 12 else { throw MotionArtworkError("Truncated video decode time.") }
                        timing = (box.content + 4, wide, wide ? head.uint64BE(4) : UInt64(head.uint32BE(4)))
                    }
                }
                if let timing, let id { times.append(Time(position: timing.0, wide: timing.1, value: timing.2, track: id)) }
            }
        }
        guard !times.isEmpty, Set(times.map(\.track)).count == 1, let first = times.map(\.value).min(), first > 0 else { return false }
        // Parse the whole structure first, so a malformed file is never partly patched.
        for time in times {
            try file.seek(toOffset: time.position)
            let value = time.value - first
            try file.write(contentsOf: time.wide ? Data.be64(value) : Data.be32(Int(value)))
        }
        return true
    }
}
