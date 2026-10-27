import Foundation

/// What would happen to a file of this name and size before any byte is sent.
enum UploadCheck: Equatable {
    /// It will be saved as [savedName] (the name itself, or a numbered one if another file has it).
    case accept(savedName: String)
    /// A file with this name and size is already there: skipped, never overwritten.
    case duplicate
    case insufficientSpace
}

/// A file being written. Nothing reaches the library until [commit]; [abort] removes every trace.
protocol PendingUpload: AnyObject {
    var savedName: String { get }
    func write(_ data: Data) throws
    func commit() throws
    func abort()
}

enum OpenedUpload {
    case opened(PendingUpload)
    case duplicate
    case insufficientSpace
}

/// Where received files go. The destination is the sink's own; clients only suggest a name.
protocol UploadSink: AnyObject, Sendable {
    func check(_ name: String, _ size: Int64) -> UploadCheck
    func open(_ name: String, _ size: Int64) throws -> OpenedUpload
}

/// Reads a request body from the connection (a socket in the app, a buffer in tests).
protocol BodyReader: AnyObject {
    /// Up to [max] bytes; nil when the connection ended, failed or stalled past the read timeout.
    func read(max: Int) async -> Data?
}

/// Limits of one transfer session.
struct TransferLimits {
    /// 2 GB: far above any ordinary audio file.
    var maxFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    var maxConcurrentUploads = 2
    var maxConnections = 8
    /// A connection that sends nothing for this long is dropped (and its partial file removed).
    var readTimeoutSeconds: Double = 30
}

/// What the coordinator wants to know (activity for the idle timeout, saved files for the library).
struct TransferEvents: Sendable {
    var onRequest: @Sendable () -> Void = {}
    var onUploadStarted: @Sendable () -> Void = {}
    var onUploadFinished: @Sendable () -> Void = {}
    var onFileSaved: @Sendable () -> Void = {}
}

/// The transfer page's routes. Only these exist:
/// - `GET /`: the upload page (no secrets in it);
/// - `POST /api/pair`: trades the typed pairing code for the session token;
/// - `POST /api/check`: would this file be saved, skipped as a duplicate or refused? (no bytes yet);
/// - `POST /api/upload`: one file as the raw request body.
/// Every `/api` request must come for this exact host and port (blocks DNS rebinding) and, from a
/// browser, from this page's own origin. The token travels in a custom header, which another site
/// cannot send without a CORS preflight this server never grants. Nothing lists, reads or deletes files.
final class TransferRouter: @unchecked Sendable {
    static let tokenHeader = "X-Transfer-Token"
    static let codeHeader = "X-Pairing-Code"
    static let nameHeader = "X-File-Name"
    static let sizeHeader = "X-File-Size"
    /// Sent by the transfer page on every API call; another site cannot send it without a preflight.
    static let clientHeader = "X-Empee3-Transfer"
    static let clientValue = "1"
    private static let bufferBytes = 64 * 1024
    private static let progressStepBytes: Int64 = 256 * 1024
    private static let duplicateMessage = "Already on the phone: skipped, nothing was overwritten"
    private static let noSpaceMessage = "Not enough free space on the phone"

    private let session: TransferSession
    private let hostPort: String
    private let sink: UploadSink
    private let registry: TransferRegistry
    private let limits: TransferLimits
    private let events: TransferEvents
    private let clock: @Sendable () -> Int64
    private let page: Data
    private let lock = NSLock()
    private var uploading = 0

    init(session: TransferSession, hostPort: String, sink: UploadSink, registry: TransferRegistry, limits: TransferLimits = TransferLimits(),
         events: TransferEvents = TransferEvents(), page: Data = TransferPage.html,
         clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.session = session
        self.hostPort = hostPort
        self.sink = sink
        self.registry = registry
        self.limits = limits
        self.events = events
        self.page = page
        self.clock = clock
    }

    /// The response to send, or nil when the connection is already gone (nothing can be sent).
    func handle(_ request: HttpRequest, body: BodyReader) async -> HttpResponse? {
        events.onRequest()
        guard request.header("host")?.lowercased() == hostPort.lowercased() else { return .error(HttpStatus.misdirectedRequest, "Wrong host") }
        switch request.path {
        case "/":
            return request.method == "GET" || request.method == "HEAD"
                ? HttpResponse(status: HttpStatus.ok, contentType: "text/html; charset=utf-8", body: page) : methodNotAllowed()
        case "/api/pair", "/api/check", "/api/upload":
            return await api(request, body)
        default:
            return .error(HttpStatus.notFound, "Not found")
        }
    }

    private func methodNotAllowed() -> HttpResponse { .error(HttpStatus.methodNotAllowed, "Method not allowed") }

    private func api(_ request: HttpRequest, _ body: BodyReader) async -> HttpResponse? {
        let origin = request.header("origin")
        if request.method != "POST" { return methodNotAllowed() }
        if let origin, origin != "http://\(hostPort)" { return .error(HttpStatus.forbidden, "Cross-origin request refused") }
        if request.header(Self.clientHeader) != Self.clientValue { return .error(HttpStatus.forbidden, "Use the transfer page") }
        if request.path == "/api/pair" { return pair(request) }
        if !session.isAuthorized(request.header(Self.tokenHeader), clock()) {
            return .error(HttpStatus.unauthorized, "This transfer session has ended or the link is wrong")
        }
        if request.path == "/api/check" { return check(request) }
        return await upload(request, body)
    }

    private func pair(_ request: HttpRequest) -> HttpResponse {
        switch session.pair(request.header(Self.codeHeader), clock()) {
        case .paired(let token): return .json(HttpStatus.ok, [("status", "ok"), ("token", token)])
        case .wrongCode: return .error(HttpStatus.forbidden, "Wrong code. Check the code shown on the phone.")
        case .locked: return .error(HttpStatus.tooManyRequests, "Too many wrong codes. Scan the QR code, or stop and start the transfer on the phone.")
        case .closed: return .error(HttpStatus.unauthorized, "This transfer session has ended")
        }
    }

    private func check(_ request: HttpRequest) -> HttpResponse {
        guard let name = TransferFiles.sanitize(decodedName(request)) else { return unsupported() }
        guard let size = request.header(Self.sizeHeader).flatMap({ Int64($0) }), size > 0 else {
            return .error(HttpStatus.badRequest, "Missing file size")
        }
        if size > limits.maxFileBytes { return tooLarge() }
        switch sink.check(name, size) {
        case .accept(let saved): return .json(HttpStatus.ok, [("status", "ok"), ("savedName", saved)])
        case .duplicate: return .json(HttpStatus.ok, [("status", "duplicate"), ("message", Self.duplicateMessage)])
        case .insufficientSpace: return noSpace()
        }
    }

    private func upload(_ request: HttpRequest, _ body: BodyReader) async -> HttpResponse? {
        guard let length = request.contentLength else { return .error(HttpStatus.lengthRequired, "Content-Length required") }
        if length > limits.maxFileBytes { return tooLarge() }
        if length == 0 { return .error(HttpStatus.badRequest, "Empty file") }
        guard let name = TransferFiles.sanitize(decodedName(request)) else { return unsupported() }
        let acquired = lock.withLock { () -> Bool in
            guard uploading < limits.maxConcurrentUploads else { return false }
            uploading += 1
            return true
        }
        if !acquired { return .error(HttpStatus.tooManyRequests, "Busy: the phone is already receiving files, this one will be retried") }
        events.onUploadStarted()
        defer {
            lock.withLock { uploading -= 1 }
            events.onUploadFinished()
        }
        do {
            switch try sink.open(name, length) {
            case .opened(let pending):
                return await receive(pending, length, body)
            case .duplicate:
                registry.duplicate(registry.begin(name, length))
                // Read and drop the bytes, so the browser receives the answer instead of a broken connection.
                return await skip(body, length) ? .json(HttpStatus.ok, [("status", "duplicate"), ("message", Self.duplicateMessage)]) : nil
            case .insufficientSpace:
                registry.failed(registry.begin(name, length), Self.noSpaceMessage)
                return noSpace()
            }
        } catch {
            registry.failed(registry.begin(name, length), "Could not create the file on the phone: \(error.localizedDescription)")
            return .error(HttpStatus.internalError, "Could not create the file on the phone")
        }
    }

    /// Streams [length] bytes into [upload]; it reaches the library only after a successful commit.
    private func receive(_ upload: PendingUpload, _ length: Int64, _ body: BodyReader) async -> HttpResponse? {
        let id = registry.begin(upload.savedName, length)
        // The first bytes decide whether this really is the audio format its name claims.
        let wanted = Int(min(length, Int64(TransferFiles.signatureBytes)))
        var head = Data()
        while head.count < wanted {
            guard let chunk = await body.read(max: wanted - head.count), !chunk.isEmpty else { return cancelled(upload, id) }
            head.append(chunk)
        }
        if !TransferFiles.looksLikeAudio(upload.savedName, [UInt8](head)) {
            upload.abort()
            registry.failed(id, "Not a valid \(TransferFiles.extensionOf(upload.savedName).uppercased()) audio file")
            return await skip(body, length - Int64(head.count)) ? unsupported() : nil
        }
        var received = Int64(head.count)
        var lastReported: Int64 = 0
        if !write(upload, id, head) { return await writeFailed(body, length - received) }
        while received < length {
            guard let chunk = await body.read(max: Int(min(Int64(Self.bufferBytes), length - received))), !chunk.isEmpty else {
                return cancelled(upload, id)
            }
            if !write(upload, id, chunk) { return await writeFailed(body, length - received - Int64(chunk.count)) }
            received += Int64(chunk.count)
            if received - lastReported >= Self.progressStepBytes {
                registry.progress(id, received)
                lastReported = received
            }
        }
        registry.finalizing(id)
        do {
            try upload.commit()
            registry.completed(id, savedName: upload.savedName)
            events.onFileSaved()
            return .json(HttpStatus.ok, [("status", "saved"), ("savedName", upload.savedName)])
        } catch {
            upload.abort()
            registry.failed(id, "Received, but the phone could not finish saving it: \(error.localizedDescription)")
            return .error(HttpStatus.internalError, "The phone could not finish saving the file")
        }
    }

    private func write(_ upload: PendingUpload, _ id: Int64, _ data: Data) -> Bool {
        do {
            try upload.write(data)
            return true
        } catch {
            upload.abort()
            registry.failed(id, "Could not write to the phone's storage (full or unavailable): \(error.localizedDescription)")
            return false
        }
    }

    private func writeFailed(_ body: BodyReader, _ remaining: Int64) async -> HttpResponse? {
        await skip(body, remaining) ? .error(HttpStatus.insufficientStorage, "The phone could not store the file") : nil
    }

    private func cancelled(_ upload: PendingUpload, _ id: Int64) -> HttpResponse? {
        upload.abort()
        registry.cancelled(id)
        return nil
    }

    /// Discards [count] bytes; false when the connection ended or failed first.
    private func skip(_ body: BodyReader, _ count: Int64) async -> Bool {
        var left = count
        while left > 0 {
            guard let chunk = await body.read(max: Int(min(Int64(Self.bufferBytes), left))), !chunk.isEmpty else { return false }
            left -= Int64(chunk.count)
        }
        return true
    }

    private func decodedName(_ request: HttpRequest) -> String? { request.header(Self.nameHeader)?.removingPercentEncoding }

    private func unsupported() -> HttpResponse {
        .error(HttpStatus.unsupportedMediaType, "Not a supported audio file (\(TransferFiles.formatsLabel))")
    }

    private func tooLarge() -> HttpResponse { .error(HttpStatus.payloadTooLarge, "File is larger than \(limits.maxFileBytes / 1024 / 1024) MB") }

    private func noSpace() -> HttpResponse { .error(HttpStatus.insufficientStorage, Self.noSpaceMessage) }
}

/// Saves received files into the music folder. A file is written under a hidden staging name in
/// the app's caches and moved into place only when complete, so the library never sees a partial
/// file. Existing files are never replaced: the same name and size is a duplicate (skipped), the
/// same name with other content gets a numbered name.
final class FolderUploadSink: UploadSink, @unchecked Sendable {
    private static let freeSpaceMargin: Int64 = 50 * 1024 * 1024
    private let folder: URL
    private let staging: URL
    private let lock = NSLock()
    private var reserved: Set<String> = []

    init(folder: URL = LibraryPaths.musicFolder, staging: URL = LibraryPaths.cachesFolder.appending(path: "transfer-partial")) {
        self.folder = folder
        self.staging = staging
    }

    func check(_ name: String, _ size: Int64) -> UploadCheck {
        lock.withLock { checkLocked(name, size) }
    }

    private func checkLocked(_ name: String, _ size: Int64) -> UploadCheck {
        if size + Self.freeSpaceMargin > freeBytes() { return .insufficientSpace }
        let existing = existingFiles()
        if existing[name.lowercased()] == size { return .duplicate }
        return .accept(savedName: freeName(name, taken: Set(existing.keys)))
    }

    func open(_ name: String, _ size: Int64) throws -> OpenedUpload {
        try lock.withLock {
            switch checkLocked(name, size) {
            case .duplicate: return .duplicate
            case .insufficientSpace: return .insufficientSpace
            case .accept(let saved):
                reserved.insert(saved.lowercased())
                do {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let partial = staging.appending(path: ".\(UUID().uuidString).part")
                    guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    let handle = try FileHandle(forWritingTo: partial)
                    return .opened(FileUpload(savedName: saved, partial: partial, target: folder.appending(path: saved), handle: handle) { [weak self] in
                        self?.release(saved)
                    })
                } catch {
                    reserved.remove(saved.lowercased())
                    throw error
                }
            }
        }
    }

    /// Removes partial files a previous session left behind.
    func cleanUpLeftovers() {
        let files = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".part") { try? FileManager.default.removeItem(at: file) }
    }

    private func release(_ name: String) { lock.withLock { _ = reserved.remove(name.lowercased()) } }

    private func freeName(_ name: String, taken: Set<String>) -> String {
        func isFree(_ candidate: String) -> Bool { !taken.contains(candidate.lowercased()) && !reserved.contains(candidate.lowercased()) }
        if isFree(name) { return name }
        var n = 2
        while !isFree(TransferFiles.numbered(name, n)) { n += 1 }
        return TransferFiles.numbered(name, n)
    }

    private func freeBytes() -> Int64 {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    /// Lower-cased file name to size of the files already in the folder.
    private func existingFiles() -> [String: Int64] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        var out: [String: Int64] = [:]
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { out[file.lastPathComponent.lowercased()] = Int64(values?.fileSize ?? 0) }
        }
        return out
    }

    private final class FileUpload: PendingUpload {
        let savedName: String
        private let partial: URL
        private let target: URL
        private let handle: FileHandle
        private let onEnd: () -> Void
        private var finished = false

        init(savedName: String, partial: URL, target: URL, handle: FileHandle, onEnd: @escaping () -> Void) {
            self.savedName = savedName
            self.partial = partial
            self.target = target
            self.handle = handle
            self.onEnd = onEnd
        }

        func write(_ data: Data) throws { try handle.write(contentsOf: data) }

        func commit() throws {
            guard !finished else { return }
            finished = true
            defer { onEnd() }
            do {
                try handle.close()
                // Never overwrites: a file that appeared meanwhile makes the move fail.
                try FileManager.default.moveItem(at: partial, to: target)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
        }

        func abort() {
            guard !finished else { return }
            finished = true
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            onEnd()
        }
    }
}
