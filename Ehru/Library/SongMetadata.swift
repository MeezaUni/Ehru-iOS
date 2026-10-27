import AVFoundation

/// Reads tags straight from the audio file. Missing tags fall back to the file name.
enum SongMetadata {
    static func read(_ url: URL) async -> Song {
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.commonMetadata, .duration) else {
            return Song(url: url, title: fallbackTitle, artist: "", album: "", duration: 0)
        }
        let (metadata, duration) = loaded
        let seconds = duration.seconds

        return Song(
            url: url,
            title: await string(.commonIdentifierTitle, in: metadata) ?? fallbackTitle,
            artist: await string(.commonIdentifierArtist, in: metadata) ?? "",
            album: await string(.commonIdentifierAlbumName, in: metadata) ?? "",
            duration: seconds.isFinite ? seconds : 0
        )
    }

    static func artworkData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first
        else { return nil }
        return try? await item.load(.dataValue)
    }

    private static func string(_ identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
