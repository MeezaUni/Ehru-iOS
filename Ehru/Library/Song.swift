import Foundation

struct Song: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    var id: URL { url }

    /// "Artist — Album", skipping whichever is missing.
    var subtitle: String {
        let parts = [artist, album].filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown artist" : parts.joined(separator: " — ")
    }
}
