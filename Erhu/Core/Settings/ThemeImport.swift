import Compression
import Foundation
import SwiftUI

/// A colour theme imported from an Android theme package (manifest.json, alone or in a .zip).
/// Only the colours iOS uses are kept; fonts, shapes and widget skins aren't applied here.
struct ImportedTheme: Codable, Equatable, Identifiable, Sendable {
    struct Colors: Codable, Equatable, Sendable {
        var primary: UInt32
        var onPrimary: UInt32
        var background: UInt32
        var surface: UInt32
        var surfaceVariant: UInt32
        var onSurface: UInt32
        var onSurfaceVariant: UInt32
        var outline: UInt32
    }

    var id: String
    var name: String
    var author: String
    var isDark: Bool
    var colors: Colors

    var palette: AppPalette {
        AppPalette(primary: Color(argb: colors.primary), onPrimary: Color(argb: colors.onPrimary),
                   background: Color(argb: colors.background), surface: Color(argb: colors.surface),
                   surfaceVariant: Color(argb: colors.surfaceVariant), onSurface: Color(argb: colors.onSurface),
                   onSurfaceVariant: Color(argb: colors.onSurfaceVariant), outline: Color(argb: colors.outline))
    }
}

enum ThemeImportError: LocalizedError, Equatable {
    case notATheme(String)
    case skin
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notATheme(let detail): "This isn't a theme package (\(detail))."
        case .skin: "This is a widget skin, not a colour theme. Skins aren't used on iOS."
        case .tooLarge: "The theme package is too large."
        }
    }
}

enum ThemeImporter {
    static let maxPackageBytes = 20 * 1024 * 1024
    private static let maxManifestBytes = 1024 * 1024

    /// The theme in [data]: a zip with a manifest.json, or the manifest itself.
    static func theme(from data: Data) throws -> ImportedTheme {
        guard data.count <= maxPackageBytes else { throw ThemeImportError.tooLarge }
        let manifest = data.starts(with: [0x50, 0x4B, 0x03, 0x04]) ? try ZipReader.file(named: "manifest.json", in: data) : data
        return try parse(manifest)
    }

    /// Reads the Android ThemeManifest JSON: colours are ARGB numbers ("primary": 4294506490).
    static func parse(_ json: Data) throws -> ImportedTheme {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ThemeImportError.notATheme("manifest.json isn't valid JSON")
        }
        guard let colors = object["colors"] as? [String: Any] else { throw ThemeImportError.skin }
        func color(_ key: String) throws -> UInt32 {
            guard let number = colors[key] as? NSNumber else { throw ThemeImportError.notATheme("no \(key) colour") }
            return UInt32(truncatingIfNeeded: number.int64Value)
        }
        let rawId = (object["id"] as? String)?.trimmed ?? ""
        let id = String(rawId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }.prefix(64).map(Character.init))
        guard !id.isEmpty, let name = (object["name"] as? String)?.trimmed.nonBlank else { throw ThemeImportError.notATheme("no id or name") }
        return ImportedTheme(
            id: "imported_\(id)", name: String(name.prefix(60)), author: (object["author"] as? String)?.trimmed.nonBlank ?? "Unknown",
            isDark: object["isDark"] as? Bool ?? true,
            colors: ImportedTheme.Colors(
                primary: try color("primary"), onPrimary: try color("onPrimary"), background: try color("background"),
                surface: try color("surface"), surfaceVariant: try color("surfaceVariant"), onSurface: try color("onSurface"),
                onSurfaceVariant: try color("onSurfaceVariant"), outline: try color("outline")
            )
        )
    }
}

/// Just enough of the ZIP format to read one small file: the central directory, then the entry's
/// local header and its stored or deflated bytes.
enum ZipReader {
    static func file(named name: String, in zip: Data) throws -> Data {
        let bytes = [UInt8](zip)
        func u16(_ at: Int) -> Int { at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { at + 4 <= bytes.count ? u16(at) | u16(at + 2) << 16 : 0 }
        // End of central directory: the last "PK\u{5}\u{6}" within the final 64 KB.
        var end = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw ThemeImportError.notATheme("not a zip file") }
        let count = u16(end + 10)
        var entry = u32(end + 16)
        for _ in 0..<count {
            guard u32(entry) == 0x0201_4B50 else { break }
            let method = u16(entry + 10)
            let compressed = u32(entry + 20)
            let size = u32(entry + 24)
            let nameLength = u16(entry + 28)
            let extra = u16(entry + 30)
            let comment = u16(entry + 32)
            let local = u32(entry + 42)
            guard entry + 46 + nameLength <= bytes.count else { break }
            let entryName = String(decoding: bytes[(entry + 46)..<(entry + 46 + nameLength)], as: UTF8.self)
            if entryName == name || entryName.hasSuffix("/" + name) {
                guard size <= 1024 * 1024, u32(local) == 0x0403_4B50 else { throw ThemeImportError.notATheme("\(name) is unreadable") }
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                guard start + compressed <= bytes.count else { throw ThemeImportError.notATheme("the zip is cut short") }
                let payload = Data(bytes[start..<(start + compressed)])
                switch method {
                case 0: return payload
                case 8: return try inflate(payload, size: size)
                default: throw ThemeImportError.notATheme("unsupported compression")
                }
            }
            entry += 46 + nameLength + extra + comment
        }
        throw ThemeImportError.notATheme("no \(name) inside")
    }

    /// Raw DEFLATE (what Compression calls ZLIB) into exactly [size] bytes.
    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeBytes { source in
            compression_decode_buffer(&output, size, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw ThemeImportError.notATheme("the zip entry couldn't be decompressed") }
        return Data(output)
    }
}
