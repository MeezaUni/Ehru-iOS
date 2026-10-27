import Foundation
import CryptoKit
import Security

/// HTTP status codes used by the transfer server.
enum HttpStatus {
    static let ok = 200
    static let badRequest = 400
    static let unauthorized = 401
    static let forbidden = 403
    static let notFound = 404
    static let methodNotAllowed = 405
    static let lengthRequired = 411
    static let payloadTooLarge = 413
    static let unsupportedMediaType = 415
    static let misdirectedRequest = 421
    static let tooManyRequests = 429
    static let headersTooLarge = 431
    static let internalError = 500
    static let serviceUnavailable = 503
    static let insufficientStorage = 507

    static func reason(_ status: Int) -> String {
        switch status {
        case ok: "OK"
        case badRequest: "Bad Request"
        case unauthorized: "Unauthorized"
        case forbidden: "Forbidden"
        case notFound: "Not Found"
        case methodNotAllowed: "Method Not Allowed"
        case lengthRequired: "Length Required"
        case payloadTooLarge: "Payload Too Large"
        case unsupportedMediaType: "Unsupported Media Type"
        case misdirectedRequest: "Misdirected Request"
        case tooManyRequests: "Too Many Requests"
        case headersTooLarge: "Request Header Fields Too Large"
        case serviceUnavailable: "Service Unavailable"
        case insufficientStorage: "Insufficient Storage"
        default: "Error"
        }
    }
}

/// A request rejected before routing (malformed, too large, unsupported).
struct HttpError: Error, Equatable {
    let status: Int
    let message: String
}

/// Request line and headers; the body is read separately by the route.
struct HttpRequest: Equatable {
    let method: String
    let path: String
    let headers: [String: String]

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Content-Length, or nil when absent (malformed values are rejected while parsing).
    var contentLength: Int64? { header("content-length").flatMap { Int64($0) } }
}

/// Minimal HTTP/1.1 request parsing for the transfer page: one request per connection, a bounded
/// head, Content-Length bodies only (no chunked requests), no keep-alive.
enum HttpParser {
    static let maxHeadBytes = 16 * 1024
    private static let maxHeaders = 64
    private static let method = Regex16("^[A-Z]{3,7}$")

    /// The end of the head ("\r\n\r\n") in [buffer]: the index just after it, or nil while incomplete.
    static func headEnd(in buffer: Data) -> Int? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    /// Reads the head from the start of [data] (a whole request in tests): 431 when it grows past the
    /// limit, 400 when it never ends.
    static func readHead(_ data: Data) throws -> HttpRequest {
        guard let end = headEnd(in: data.prefix(maxHeadBytes + 1)) else {
            if data.count > maxHeadBytes { throw HttpError(status: HttpStatus.headersTooLarge, message: "Request head too large") }
            throw HttpError(status: HttpStatus.badRequest, message: "Incomplete request")
        }
        if end > maxHeadBytes { throw HttpError(status: HttpStatus.headersTooLarge, message: "Request head too large") }
        return try parse(head: data.prefix(end - 4))
    }

    /// Parses a complete head (without its final blank line).
    static func parse(head: Data) throws -> HttpRequest {
        guard let text = String(data: head, encoding: .isoLatin1) else { throw HttpError(status: HttpStatus.badRequest, message: "Bad request") }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].components(separatedBy: " ")
        guard parts.count == 3, method.matchesEntirely(parts[0]), parts[2].hasPrefix("HTTP/1.") else {
            throw HttpError(status: HttpStatus.badRequest, message: "Bad request line")
        }
        let target = parts[1]
        guard target.hasPrefix("/") else { throw HttpError(status: HttpStatus.badRequest, message: "Bad request target") }
        let path = String(target.prefix { $0 != "?" && $0 != "#" })
        let headerLines = lines.dropFirst().filter { !$0.isEmpty }
        if headerLines.count > maxHeaders { throw HttpError(status: HttpStatus.headersTooLarge, message: "Too many headers") }
        var headers: [String: String] = [:]
        for line in headerLines {
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else {
                throw HttpError(status: HttpStatus.badRequest, message: "Bad header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" && headers[name] != nil {
                throw HttpError(status: HttpStatus.badRequest, message: "Repeated Content-Length")
            }
            headers[name] = value
        }
        if let length = headers["content-length"], (Int64(length) ?? -1) < 0 {
            throw HttpError(status: HttpStatus.badRequest, message: "Bad Content-Length")
        }
        if headers["transfer-encoding"] != nil { throw HttpError(status: HttpStatus.lengthRequired, message: "Send a Content-Length body") }
        guard let decoded = path.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding else {
            throw HttpError(status: HttpStatus.badRequest, message: "Bad path encoding")
        }
        return HttpRequest(method: parts[0], path: decoded, headers: headers)
    }
}

/// A complete response (always small: pages, JSON results). Every response closes the connection.
struct HttpResponse: Equatable {
    let status: Int
    let contentType: String
    let body: Data

    /// Everything the page needs is inline; it may only talk to this phone.
    private static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; " +
        "img-src 'self' data:; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"

    var bytes: Data {
        var head = "HTTP/1.1 \(status) \(HttpStatus.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Content-Security-Policy: \(Self.csp)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func json(_ status: Int, _ fields: [(String, Any?)]) -> HttpResponse {
        HttpResponse(status: status, contentType: "application/json; charset=utf-8", body: Data(TransferJSON.object(fields).utf8))
    }

    static func error(_ status: Int, _ message: String) -> HttpResponse { json(status, [("status", "error"), ("message", message)]) }
}

/// Just enough JSON for flat result objects ("<" escaped so a name can never close a script tag).
enum TransferJSON {
    static func object(_ fields: [(String, Any?)]) -> String {
        "{" + fields.map { "\(string($0.0)):\(value($0.1))" }.joined(separator: ",") + "}"
    }

    private static func value(_ v: Any?) -> String {
        switch v {
        case nil: "null"
        case let b as Bool: b ? "true" : "false"
        case let n as Int: String(n)
        case let n as Int64: String(n)
        case let s as String: string(s)
        default: string(String(describing: v!))
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "<": out += "\\u003c"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// File names and formats accepted by Wi-Fi Transfer. The browser only ever supplies a display
/// name: any folder part is discarded, so a client can never choose where a file is written.
enum TransferFiles {
    /// Ordinary local audio formats iOS plays (no conversion is done). Ogg and Opus, which Android
    /// accepts, are left out: iOS cannot play them.
    static let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "wav", "aif", "aiff"]
    static let formatsLabel = "MP3, FLAC, M4A, AAC, WAV or AIFF"
    private static let maxBaseLength = 120
    private static let reserved = Regex16(#"[<>:"/\\|?*\x{0000}-\x{001F}\x{007F}]"#)
    private static let whitespace = Regex16(#"\s+"#)

    /// A safe file name for [raw] (last path segment only, no control or reserved characters, no
    /// leading dots, at most 120 characters before the extension), or nil when nothing usable is left
    /// or the extension is not a supported audio format.
    static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lastSegment = raw.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? raw
        let segment = lastSegment.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? lastSegment
        var cleaned = whitespace.replacing(in: reserved.replacing(in: segment, with: "_"), with: " ").trimmed
        cleaned = trim(cleaned, leading: true)
        cleaned = trim(cleaned, leading: false)
        guard let dot = cleaned.lastIndex(of: "."), dot > cleaned.startIndex, cleaned.index(after: dot) < cleaned.endIndex else { return nil }
        let ext = cleaned[cleaned.index(after: dot)...].lowercased()
        var base = trim(String(cleaned[..<dot]), leading: false)
        base = trim(String(base.prefix(maxBaseLength)), leading: false)
        let usable = !base.isEmpty && base != "." && base != ".."
        return audioExtensions.contains(ext) && usable ? "\(base).\(ext)" : nil
    }

    /// Trims dots and spaces from one end.
    private static func trim(_ text: String, leading: Bool) -> String {
        let set: Set<Character> = [".", " "]
        if leading { return String(text.drop { set.contains($0) }) }
        var out = text
        while let last = out.last, set.contains(last) { out.removeLast() }
        return out
    }

    static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// "Song (2).mp3" for "Song.mp3" and 2: the predictable name used on a collision.
    static func numbered(_ name: String, _ n: Int) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "\(name) (\(n))" }
        return "\(name[..<dot]) (\(n))\(name[dot...])"
    }

    /// Bytes needed by [looksLikeAudio].
    static let signatureBytes = 12

    /// Whether the first bytes match the format the extension claims (MP3 frame or ID3 tag, FLAC,
    /// MP4 "ftyp", ADTS AAC, RIFF/WAVE, AIFF). A renamed non-audio file is refused.
    static func looksLikeAudio(_ name: String, _ header: [UInt8]) -> Bool {
        guard header.count >= 4 else { return false }
        func at(_ i: Int) -> Int { i < header.count ? Int(header[i]) : -1 }
        func ascii(_ offset: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            return offset + bytes.count <= header.count && bytes.indices.allSatisfy { at(offset + $0) == Int(bytes[$0]) }
        }
        let id3 = ascii(0, "ID3")
        let frameSync = at(0) == 0xFF && (at(1) & 0xE0) == 0xE0
        switch extensionOf(name) {
        case "mp3": return id3 || frameSync
        case "flac": return ascii(0, "fLaC") || id3
        case "m4a": return ascii(4, "ftyp")
        case "aac": return (at(0) == 0xFF && (at(1) & 0xF6) == 0xF0) || ascii(0, "ADIF") || id3
        case "wav": return ascii(0, "RIFF") && ascii(8, "WAVE")
        case "aif", "aiff": return ascii(0, "FORM") && (ascii(8, "AIFF") || ascii(8, "AIFC"))
        default: return false
        }
    }
}

/// Outcome of entering the pairing code in the browser.
enum PairResult: Equatable {
    case paired(token: String)
    case wrongCode
    /// Too many wrong codes: pairing by code is off for the rest of this session (the QR code still works).
    case locked
    case closed
}

/// One transfer session, from Start to Stop: a 256-bit [token] (in the QR code, never typed) and a
/// 6-digit [pairingCode] for typing the address by hand, which trades for the token and locks after
/// a few wrong tries. Nothing is valid after [close] or after [expiresAtMs].
final class TransferSession: @unchecked Sendable, CustomStringConvertible {
    static let defaultMaxPairAttempts = 5
    /// Hard limit on a session's life, whatever happens: 3 hours.
    static let defaultLifetimeMs: Int64 = 3 * 60 * 60 * 1000

    let token: String
    let pairingCode: String
    let createdAtMs: Int64
    let expiresAtMs: Int64
    private let maxPairAttempts: Int
    private let lock = NSLock()
    private var closed = false
    private var failedPairs = 0

    init(token: String, pairingCode: String, createdAtMs: Int64, expiresAtMs: Int64, maxPairAttempts: Int) {
        self.token = token
        self.pairingCode = pairingCode
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
        self.maxPairAttempts = maxPairAttempts
    }

    static func create(nowMs: Int64, lifetimeMs: Int64 = defaultLifetimeMs, maxPairAttempts: Int = defaultMaxPairAttempts) -> TransferSession {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "no secure random")
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var codeBytes = [UInt8](repeating: 0, count: 4)
        precondition(SecRandomCopyBytes(kSecRandomDefault, codeBytes.count, &codeBytes) == errSecSuccess, "no secure random")
        let value = codeBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return TransferSession(token: token, pairingCode: String(format: "%06d", value), createdAtMs: nowMs,
                               expiresAtMs: nowMs + lifetimeMs, maxPairAttempts: maxPairAttempts)
    }

    func isOpen(_ nowMs: Int64) -> Bool { lock.withLock { !closed && nowMs < expiresAtMs } }

    /// True only for the exact token of an open session (constant-time comparison).
    func isAuthorized(_ candidate: String?, _ nowMs: Int64) -> Bool {
        guard let candidate, isOpen(nowMs) else { return false }
        return Self.constantTimeEquals(candidate, token)
    }

    func pair(_ code: String?, _ nowMs: Int64) -> PairResult {
        lock.withLock {
            if closed || nowMs >= expiresAtMs { return .closed }
            if failedPairs >= maxPairAttempts { return .locked }
            if let code, Self.constantTimeEquals(code.trimmed, pairingCode) { return .paired(token: token) }
            failedPairs += 1
            return failedPairs >= maxPairAttempts ? .locked : .wrongCode
        }
    }

    func close() { lock.withLock { closed = true } }

    /// Credentials are never shown in logs.
    var description: String { "TransferSession(created=\(createdAtMs), expires=\(expiresAtMs))" }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }
}

enum TransferStatus: Equatable, Sendable {
    case receiving, finalizing, completed, duplicate, failed, cancelled

    var isTerminal: Bool {
        switch self {
        case .receiving, .finalizing: false
        default: true
        }
    }
}

/// One file of the session as the phone sees it. [name] is the name it is (or would be) saved under.
struct TransferItem: Identifiable, Equatable, Sendable {
    let id: Int64
    var name: String
    let sizeBytes: Int64
    var receivedBytes: Int64 = 0
    var status: TransferStatus = .receiving
    /// Why it failed / was skipped, in words the user can act on.
    var message: String?
}

/// Per-file transfer states of a session. Only forward transitions out of non-terminal states are
/// allowed: a finished, failed or cancelled file never changes again.
final class TransferRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextId: Int64 = 1
    private var list: [TransferItem] = []
    /// Called (on any thread) after every change.
    var onChange: (@Sendable ([TransferItem]) -> Void)?

    var items: [TransferItem] { lock.withLock { list } }

    func begin(_ name: String, _ sizeBytes: Int64) -> Int64 {
        let id = lock.withLock { () -> Int64 in
            let id = nextId
            nextId += 1
            list.append(TransferItem(id: id, name: name, sizeBytes: sizeBytes))
            return id
        }
        notify()
        return id
    }

    @discardableResult
    func progress(_ id: Int64, _ received: Int64) -> Bool { move(id, [.receiving]) { $0.receivedBytes = received } }

    @discardableResult
    func finalizing(_ id: Int64) -> Bool {
        move(id, [.receiving]) {
            $0.status = .finalizing
            $0.receivedBytes = $0.sizeBytes
        }
    }

    @discardableResult
    func completed(_ id: Int64, savedName: String) -> Bool {
        move(id, [.finalizing]) {
            $0.status = .completed
            $0.name = savedName
            $0.message = nil
        }
    }

    @discardableResult
    func duplicate(_ id: Int64) -> Bool {
        move(id, [.receiving, .finalizing]) {
            $0.status = .duplicate
            $0.message = "Already on the phone: skipped, nothing was overwritten"
        }
    }

    @discardableResult
    func failed(_ id: Int64, _ message: String) -> Bool {
        move(id, [.receiving, .finalizing]) {
            $0.status = .failed
            $0.message = message
        }
    }

    @discardableResult
    func cancelled(_ id: Int64) -> Bool {
        move(id, [.receiving, .finalizing]) {
            $0.status = .cancelled
            $0.message = "Cancelled before it finished"
        }
    }

    /// Ends every unfinished file (the session is stopping).
    func cancelAllActive() {
        for item in items where !item.status.isTerminal { cancelled(item.id) }
    }

    func clear() {
        lock.withLock { list = [] }
        notify()
    }

    @discardableResult
    private func move(_ id: Int64, _ from: Set<TransferStatus>, _ change: (inout TransferItem) -> Void) -> Bool {
        let applied = lock.withLock { () -> Bool in
            guard let index = list.firstIndex(where: { $0.id == id }), from.contains(list[index].status) else { return false }
            change(&list[index])
            return true
        }
        if applied { notify() }
        return applied
    }

    private func notify() { onChange?(items) }
}

extension TransferStatus: Hashable {}
