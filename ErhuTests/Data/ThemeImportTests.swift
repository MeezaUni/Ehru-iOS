import Compression
@testable import Erhu
import XCTest

final class ThemeImportTests: XCTestCase {
    private let manifest = """
    {"id":"neon night","name":"Neon Night","author":"Lochan","schemaVersion":1,"isDark":true,
     "colors":{"primary":4294902015,"onPrimary":4278190080,"primaryContainer":0,"onPrimaryContainer":0,"secondary":0,"onSecondary":0,
     "background":4278716424,"onBackground":0,"surface":4279769112,"onSurface":4294967295,"surfaceVariant":4281348144,
     "onSurfaceVariant":4290822336,"outline":4283453520,"bevelLight":0,"bevelDark":0,"lcdBackground":0,"lcdText":0,"lcdGlow":0,
     "cardBackground":0,"glassScrim":0}}
    """

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }

    /// A one-file zip, the file stored or deflated.
    private func zip(_ name: String, _ content: Data, deflate: Bool) -> Data {
        var payload = content
        if deflate {
            var out = [UInt8](repeating: 0, count: content.count + 64)
            let size = content.withUnsafeBytes { source in
                compression_encode_buffer(&out, out.count, source.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB)
            }
            payload = Data(out.prefix(size))
        }
        let nameBytes = Array(name.utf8)
        let method = deflate ? 8 : 0
        var local: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        for part in [le16(20), le16(0), le16(method), le32(0), le32(0), le32(payload.count), le32(content.count),
                     le16(nameBytes.count), le16(0), nameBytes] {
            local.append(contentsOf: part)
        }
        var central: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        for part in [le16(20), le16(20), le16(0), le16(method), le32(0), le32(0), le32(payload.count), le32(content.count),
                     le16(nameBytes.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(0), nameBytes] {
            central.append(contentsOf: part)
        }
        let centralOffset = local.count + payload.count
        var end: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        for part in [le16(0), le16(0), le16(1), le16(1), le32(central.count), le32(centralOffset), le16(0)] {
            end.append(contentsOf: part)
        }
        return Data(local) + payload + Data(central) + Data(end)
    }

    func testAManifestImportsItsColours() throws {
        let theme = try ThemeImporter.theme(from: Data(manifest.utf8))
        XCTAssertEqual(theme.id, "imported_neonnight")
        XCTAssertEqual(theme.name, "Neon Night")
        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.colors.primary, 0xFFFF_00FF)
        XCTAssertEqual(theme.colors.onSurface, 0xFFFF_FFFF)
    }

    func testZipPackagesStoredOrDeflated() throws {
        for deflate in [false, true] {
            let theme = try ThemeImporter.theme(from: zip("neon/manifest.json", Data(manifest.utf8), deflate: deflate))
            XCTAssertEqual(theme.name, "Neon Night")
        }
    }

    func testWhatIsNotAThemeIsRefused() {
        XCTAssertThrowsError(try ThemeImporter.theme(from: Data("{\"id\":\"x\",\"name\":\"Skin\"}".utf8))) { error in
            XCTAssertEqual(error as? ThemeImportError, .skin)
        }
        XCTAssertThrowsError(try ThemeImporter.theme(from: Data("not json".utf8)))
        XCTAssertThrowsError(try ThemeImporter.theme(from: zip("readme.txt", Data("hi".utf8), deflate: false)))
        XCTAssertThrowsError(try ThemeImporter.theme(from: Data("{\"id\":\"\",\"name\":\"X\",\"colors\":{}}".utf8)))
    }
}
