import XCTest
@testable import Erhu

/// A minimal valid MP3 body (ID3 header + padding) of [size] bytes.
private func mp3Bytes(_ size: Int) -> Data {
    var data = Data(count: size)
    data.replaceSubrange(0..<min(3, size), with: Array("ID3".utf8).prefix(size))
    return data
}

/// A request body in memory: it can end early ([available]) or fail after some bytes ([failAfter]).
private final class MemoryBody: BodyReader {
    private var data: Data
    private var failAfter: Int?
    private var read = 0
    var gate: (() async -> Void)?

    init(_ data: Data, available: Int? = nil, failAfter: Int? = nil) {
        self.data = available.map { data.prefix($0) } ?? data
        self.failAfter = failAfter
    }

    func read(max: Int) async -> Data? {
        if let gate {
            self.gate = nil
            await gate()
        }
        if let failAfter, read >= failAfter { return nil }
        guard !data.isEmpty else { return nil }
        var count = min(max, data.count)
        if let failAfter { count = min(count, failAfter - read) }
        let chunk = data.prefix(count)
        data = Data(data.dropFirst(count))
        read += count
        return Data(chunk)
    }
}

/// In-memory destination: [existing] are the files already "on the phone" (name to size).
private final class FakeSink: UploadSink, @unchecked Sendable {
    var existing: [String: Int64] = [:]
    var freeBytes = Int64.max
    /// Throw on write once this many bytes have been written (a full disk).
    var failWriteAfter = Int.max
    var committed: [String: Data] = [:]
    var pending: [Pending] = []
    private var reserved: Set<String> = []
    private let lock = NSLock()

    func check(_ name: String, _ size: Int64) -> UploadCheck {
        lock.withLock {
            if existing[name] == size { return .duplicate }
            if size > freeBytes { return .insufficientSpace }
            return .accept(savedName: freeName(name))
        }
    }

    func open(_ name: String, _ size: Int64) throws -> OpenedUpload {
        switch check(name, size) {
        case .duplicate: return .duplicate
        case .insufficientSpace: return .insufficientSpace
        case .accept(let saved):
            return lock.withLock {
                reserved.insert(saved)
                let upload = Pending(savedName: saved, sink: self)
                pending.append(upload)
                return .opened(upload)
            }
        }
    }

    private func freeName(_ name: String) -> String {
        func free(_ c: String) -> Bool { existing[c] == nil && !reserved.contains(c) && committed[c] == nil }
        if free(name) { return name }
        var n = 2
        while !free(TransferFiles.numbered(name, n)) { n += 1 }
        return TransferFiles.numbered(name, n)
    }

    final class Pending: PendingUpload {
        let savedName: String
        private unowned let sink: FakeSink
        var bytes = Data()
        var commits = 0
        var aborts = 0
        private var finished = false

        init(savedName: String, sink: FakeSink) {
            self.savedName = savedName
            self.sink = sink
        }

        func write(_ data: Data) throws {
            if bytes.count + data.count > sink.failWriteAfter { throw CocoaError(.fileWriteOutOfSpace) }
            bytes.append(data)
        }

        func commit() throws {
            guard !finished else { return }
            finished = true
            commits += 1
            sink.lock.withLock {
                sink.committed[savedName] = bytes
                sink.existing[savedName] = Int64(bytes.count)
                sink.reserved.remove(savedName)
            }
        }

        func abort() {
            guard !finished else { return }
            finished = true
            aborts += 1
            sink.lock.withLock { _ = sink.reserved.remove(savedName) }
        }
    }
}

final class TransferCoreTests: XCTestCase {
    func testSessionsGetFreshRandomCredentialsAndStopWorkingWhenClosedOrExpired() {
        let a = TransferSession.create(nowMs: 0)
        let b = TransferSession.create(nowMs: 0)
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertGreaterThanOrEqual(a.token.count, 43)
        XCTAssertTrue(Regex16(#"^\d{6}$"#).matchesEntirely(a.pairingCode))
        XCTAssertFalse(a.description.contains(a.token))
        XCTAssertTrue(a.isAuthorized(a.token, 1))
        XCTAssertFalse(a.isAuthorized(b.token, 1))
        XCTAssertFalse(a.isAuthorized(nil, 1))
        XCTAssertFalse(a.isAuthorized(String(a.token.dropLast()), 1))
        XCTAssertFalse(a.isAuthorized(a.token, TransferSession.defaultLifetimeMs))
        a.close()
        XCTAssertFalse(a.isAuthorized(a.token, 1))
        XCTAssertEqual(.closed, a.pair(a.pairingCode, 1))
    }

    func testThePairingCodeLocksAfterRepeatedWrongGuesses() {
        let session = TransferSession.create(nowMs: 0, maxPairAttempts: 3)
        let wrong = session.pairingCode == "000000" ? "000001" : "000000"
        XCTAssertEqual(.wrongCode, session.pair(wrong, 1))
        XCTAssertEqual(.wrongCode, session.pair(nil, 1))
        XCTAssertEqual(.locked, session.pair(wrong, 1))
        XCTAssertEqual(.locked, session.pair(session.pairingCode, 1))
        XCTAssertTrue(session.isAuthorized(session.token, 1))
        let fresh = TransferSession.create(nowMs: 0)
        XCTAssertEqual(.paired(token: fresh.token), fresh.pair(" \(fresh.pairingCode) ", 1))
    }

    func testFileNamesLoseAnyPathAndUnsafeCharacters() {
        XCTAssertEqual("song.mp3", TransferFiles.sanitize("../../../data/data/com.app/song.mp3"))
        XCTAssertEqual("song.mp3", TransferFiles.sanitize("C:\\Users\\me\\Music\\song.mp3"))
        XCTAssertEqual("evil.flac", TransferFiles.sanitize("/sdcard/../../evil.flac"))
        XCTAssertEqual("a_b_c.mp3", TransferFiles.sanitize("a<b>c.mp3"))
        XCTAssertEqual("Track 01.m4a", TransferFiles.sanitize("  Track   01.M4A  "))
        XCTAssertEqual("hidden.mp3", TransferFiles.sanitize("...hidden.mp3"))
        XCTAssertEqual("nul_byte.mp3", TransferFiles.sanitize("nul\u{0}byte.mp3"))
        XCTAssertNil(TransferFiles.sanitize(".."))
        XCTAssertNil(TransferFiles.sanitize("../"))
        XCTAssertNil(TransferFiles.sanitize(".mp3"))
        XCTAssertNil(TransferFiles.sanitize("song"))
        XCTAssertNil(TransferFiles.sanitize("payload.apk"))
        XCTAssertNil(TransferFiles.sanitize("song.mp3.exe"))
        XCTAssertNil(TransferFiles.sanitize(""))
        XCTAssertNil(TransferFiles.sanitize(nil))
        XCTAssertNil(TransferFiles.sanitize("song.ogg"), "iOS cannot play Ogg")
        XCTAssertEqual(124, TransferFiles.sanitize(String(repeating: "x", count: 500) + ".mp3")?.count)
        XCTAssertEqual("Song (2).mp3", TransferFiles.numbered("Song.mp3", 2))
    }

    func testContentMustMatchTheClaimedAudioFormat() {
        func header(_ text: String) -> [UInt8] { Array((Array(text.utf8) + [UInt8](repeating: 0, count: 12)).prefix(12)) }
        XCTAssertTrue(TransferFiles.looksLikeAudio("a.mp3", header("ID3")))
        XCTAssertTrue(TransferFiles.looksLikeAudio("a.mp3", [0xFF, 0xFB, 0, 0]))
        XCTAssertTrue(TransferFiles.looksLikeAudio("a.flac", header("fLaC")))
        XCTAssertTrue(TransferFiles.looksLikeAudio("a.m4a", [0, 0, 0, 0x20] + Array("ftypM4A ".utf8)))
        XCTAssertTrue(TransferFiles.looksLikeAudio("a.wav", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)))
        XCTAssertTrue(TransferFiles.looksLikeAudio("a.aiff", Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8)))
        XCTAssertFalse(TransferFiles.looksLikeAudio("a.mp3", header("MZ")))
        XCTAssertFalse(TransferFiles.looksLikeAudio("a.flac", header("<html>")))
        XCTAssertFalse(TransferFiles.looksLikeAudio("a.wav", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI ".utf8)))
        XCTAssertFalse(TransferFiles.looksLikeAudio("a.mp3", Array("ID".utf8)))
    }

    func testTransferStatesOnlyMoveForwardAndFinishOnce() {
        let registry = TransferRegistry()
        let id = registry.begin("a.mp3", 100)
        XCTAssertTrue(registry.progress(id, 40))
        XCTAssertTrue(registry.finalizing(id))
        XCTAssertFalse(registry.progress(id, 50))
        XCTAssertTrue(registry.completed(id, savedName: "a.mp3"))
        XCTAssertFalse(registry.completed(id, savedName: "a (2).mp3"))
        XCTAssertFalse(registry.failed(id, "late failure"))
        XCTAssertFalse(registry.cancelled(id))
        XCTAssertEqual(.completed, registry.items.first?.status)
        XCTAssertEqual(100, registry.items.first?.receivedBytes)
        let other = registry.begin("b.mp3", 10)
        registry.cancelAllActive()
        XCTAssertEqual(.cancelled, registry.items.first { $0.id == other }?.status)
        XCTAssertEqual(.completed, registry.items.first { $0.id == id }?.status)
        XCTAssertFalse(registry.completed(other, savedName: "b.mp3"))
    }

    func testJsonEscapesEverythingAPageCouldMisread() {
        XCTAssertEqual(#"{"a":"x\"y\\z\u003c/script>\u0001","n":3,"b":true,"z":null}"#,
                       TransferJSON.object([("a", "x\"y\\z</script>\u{1}"), ("n", 3), ("b", true), ("z", nil)]))
    }
}

final class TransferRouterTests: XCTestCase {
    private let host = "192.168.1.20:8770"
    private let session = TransferSession.create(nowMs: 0)
    private let sink = FakeSink()
    private let registry = TransferRegistry()
    private let saved = Counter()
    // Built once per test, before any concurrent task touches it (a lazy var could be built twice).
    private var router: TransferRouter!

    override func setUp() {
        super.setUp()
        router = TransferRouter(
            session: session, hostPort: host, sink: sink, registry: registry, limits: TransferLimits(maxFileBytes: 1_000_000),
            events: TransferEvents(onFileSaved: { [saved] in saved.increment() }), clock: { 1 }
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private func request(_ method: String, _ path: String, _ headers: [(String, String)] = []) -> HttpRequest {
        let all = [("Host", host)] + headers
        let head = "\(method) \(path) HTTP/1.1\r\n" + all.map { "\($0.0): \($0.1)\r\n" }.joined() + "\r\n"
        return try! HttpParser.readHead(Data(head.utf8))
    }

    /// [token]: nil sends the session's token, .some(nil) sends none.
    private func api(token: String?? = nil, _ extra: [(String, String)] = []) -> [(String, String)] {
        var headers = [(TransferRouter.clientHeader, TransferRouter.clientValue)]
        let value: String? = token == nil ? session.token : token!
        if let value { headers.append((TransferRouter.tokenHeader, value)) }
        return headers + extra
    }

    private func upload(_ name: String, _ body: Data, token: String?? = nil, reader: BodyReader? = nil, length: Int? = nil) async -> HttpResponse? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let headers = api(token: token, [(TransferRouter.nameHeader, encoded), ("Content-Length", "\(length ?? body.count)")])
        return await router.handle(request("POST", "/api/upload", headers), body: reader ?? MemoryBody(body))
    }

    private func text(_ response: HttpResponse?) -> String { String(data: response?.body ?? Data(), encoding: .utf8) ?? "" }

    func testThePageIsServedWithoutCredentialsButHoldsNone() async {
        let page = await router.handle(request("GET", "/"), body: MemoryBody(Data()))
        XCTAssertEqual(200, page?.status)
        XCTAssertFalse(text(page).contains(session.token) || text(page).contains(session.pairingCode))
        let traversal = await router.handle(request("GET", "/../../etc/passwd"), body: MemoryBody(Data()))
        XCTAssertEqual(404, traversal?.status)
        let listing = await router.handle(request("GET", "/api/files"), body: MemoryBody(Data()))
        XCTAssertEqual(404, listing?.status)
        let delete = await router.handle(request("DELETE", "/"), body: MemoryBody(Data()))
        XCTAssertEqual(405, delete?.status)
        let getUpload = await router.handle(request("GET", "/api/upload", api()), body: MemoryBody(Data()))
        XCTAssertEqual(405, getUpload?.status)
    }

    func testUploadsNeedTheSessionTokenThePageHeaderTheRightHostAndOrigin() async {
        let body = mp3Bytes(1000)
        let noToken = await upload("a.mp3", body, token: .some(.none))
        XCTAssertEqual(401, noToken?.status)
        let forged = await upload("a.mp3", body, token: "forged")
        XCTAssertEqual(401, forged?.status)
        let noClient = await router.handle(request("POST", "/api/upload", [(TransferRouter.tokenHeader, session.token),
                                                                            (TransferRouter.nameHeader, "a.mp3"), ("Content-Length", "1000")]),
                                           body: MemoryBody(body))
        XCTAssertEqual(403, noClient?.status)
        let evil = await router.handle(request("POST", "/api/upload", api([("Origin", "http://evil.example"), (TransferRouter.nameHeader, "a.mp3"),
                                                                           ("Content-Length", "1000")])), body: MemoryBody(body))
        XCTAssertEqual(403, evil?.status)
        let rebound = try! HttpParser.readHead(Data("POST /api/check HTTP/1.1\r\nHost: evil.example:8770\r\n\r\n".utf8))
        let reboundResponse = await router.handle(rebound, body: MemoryBody(Data()))
        XCTAssertEqual(421, reboundResponse?.status)
        session.close()
        let closed = await upload("a.mp3", body)
        XCTAssertEqual(401, closed?.status)
        XCTAssertTrue(sink.committed.isEmpty && registry.items.isEmpty)
    }

    func testAValidUploadIsSavedOnceAndReported() async {
        let body = mp3Bytes(200_000)
        let response = await upload("../../Music/My Song.mp3", body)
        XCTAssertEqual(200, response?.status)
        XCTAssertTrue(text(response).contains("\"saved\""))
        XCTAssertEqual(body, sink.committed["My Song.mp3"])
        XCTAssertEqual(1, sink.pending.first?.commits)
        XCTAssertEqual(0, sink.pending.first?.aborts)
        XCTAssertEqual(1, saved.count)
        XCTAssertEqual(.completed, registry.items.first?.status)
        XCTAssertEqual(200_000, registry.items.first?.receivedBytes)
    }

    func testDuplicatesAreSkippedAndNameClashesGetANumberedName() async {
        let body = mp3Bytes(5_000)
        let first = await upload("Song.mp3", body)
        XCTAssertEqual(200, first?.status)
        let dup = await upload("Song.mp3", body)
        XCTAssertTrue(text(dup).contains("\"duplicate\""))
        XCTAssertEqual(.duplicate, registry.items.last?.status)
        let other = await upload("Song.mp3", mp3Bytes(6_000))
        XCTAssertEqual(200, other?.status)
        XCTAssertEqual(Set(["Song.mp3", "Song (2).mp3"]), Set(sink.committed.keys))
        XCTAssertEqual(1, sink.pending.filter { $0.savedName == "Song.mp3" }.count)
    }

    func testTheCheckEndpointAnswersBeforeAnyByteIsSent() async {
        sink.existing["Known.flac"] = 10
        func check(_ name: String, _ size: Int64) async -> HttpResponse? {
            await router.handle(request("POST", "/api/check", api([(TransferRouter.nameHeader, name), (TransferRouter.sizeHeader, "\(size)")])),
                                body: MemoryBody(Data()))
        }
        let duplicate = await check("Known.flac", 10)
        XCTAssertTrue(text(duplicate).contains("duplicate"))
        let renamed = await check("Known.flac", 11)
        XCTAssertTrue(text(renamed).contains("Known (2).flac"))
        let exe = await check("setup.exe", 10)
        XCTAssertEqual(415, exe?.status)
        let big = await check("big.mp3", 2_000_000)
        XCTAssertEqual(413, big?.status)
        sink.freeBytes = 5
        let full = await check("new.mp3", 10)
        XCTAssertEqual(507, full?.status)
    }

    func testInvalidRequestsAreRefusedBeforeAnythingIsWritten() async {
        let big = await upload("big.mp3", Data(), length: 2_000_000)
        XCTAssertEqual(413, big?.status)
        let empty = await upload("empty.mp3", Data())
        XCTAssertEqual(400, empty?.status)
        let text = await upload("notes.txt", mp3Bytes(100))
        XCTAssertEqual(415, text?.status)
        let dots = await upload("..", mp3Bytes(100))
        XCTAssertEqual(415, dots?.status)
        let noLength = await router.handle(request("POST", "/api/upload", api([(TransferRouter.nameHeader, "a.mp3")])), body: MemoryBody(Data()))
        XCTAssertEqual(411, noLength?.status)
        let fake = await upload("fake.mp3", Data("MZ this is not audio".utf8))
        XCTAssertEqual(415, fake?.status)
        XCTAssertEqual(1, sink.pending.first?.aborts)
        XCTAssertEqual(.failed, registry.items.first?.status)
        XCTAssertTrue(sink.committed.isEmpty)
    }

    func testACancelledOrBrokenUploadLeavesNothingBehind() async {
        let body = mp3Bytes(100_000)
        let half = await upload("half.mp3", body, reader: MemoryBody(body, available: 50_000), length: 100_000)
        XCTAssertNil(half)
        let reset = await upload("reset.mp3", body, reader: MemoryBody(body, failAfter: 70_000), length: 100_000)
        XCTAssertNil(reset)
        XCTAssertTrue(sink.committed.isEmpty)
        XCTAssertTrue(sink.pending.allSatisfy { $0.aborts == 1 && $0.commits == 0 })
        XCTAssertTrue(registry.items.allSatisfy { $0.status == .cancelled })
        XCTAssertEqual(0, saved.count)
    }

    func testAFullDiskFailsThatFileOnly() async {
        let first = await upload("first.mp3", mp3Bytes(1_000))
        XCTAssertEqual(200, first?.status)
        sink.failWriteAfter = 10_000
        let second = await upload("second.mp3", mp3Bytes(50_000))
        XCTAssertEqual(507, second?.status)
        XCTAssertEqual(["first.mp3"], Array(sink.committed.keys))
        XCTAssertEqual([.completed, .failed], registry.items.map(\.status))
        XCTAssertTrue(registry.items.last?.message?.contains("storage") == true)
    }

    func testMoreParallelUploadsThanAllowedAreAskedToRetry() async {
        let body = mp3Bytes(1_000)
        let release = AsyncGate()
        let started = AsyncCounter()
        func slow() -> MemoryBody {
            let reader = MemoryBody(body)
            reader.gate = {
                await started.increment()
                await release.wait()
            }
            return reader
        }
        let a = Task { await self.upload("slow0.mp3", body, reader: slow())?.status }
        let b = Task { await self.upload("slow1.mp3", body, reader: slow())?.status }
        while await started.value < 2 { await Task.yield() }
        let third = await upload("third.mp3", body)
        XCTAssertEqual(429, third?.status)
        await release.open()
        let results = [await a.value, await b.value]
        XCTAssertEqual([200, 200], results)
        XCTAssertEqual(2, sink.committed.count)
    }

    func testPairingByCodeReturnsTheTokenAndLocksAfterWrongCodes() async {
        func pair(_ code: String) async -> HttpResponse? {
            await router.handle(request("POST", "/api/pair", api(token: .some(.none), [(TransferRouter.codeHeader, code)])), body: MemoryBody(Data()))
        }
        let wrong = session.pairingCode == "123456" ? "654321" : "123456"
        let refused = await pair(wrong)
        XCTAssertEqual(403, refused?.status)
        let ok = await pair(session.pairingCode)
        XCTAssertEqual(200, ok?.status)
        XCTAssertTrue(text(ok).contains(session.token))
        for _ in 0..<TransferSession.defaultMaxPairAttempts { _ = await pair(wrong) }
        let locked = await pair(session.pairingCode)
        XCTAssertEqual(429, locked?.status)
    }

    func testMalformedRequestsAreRejectedByTheParser() {
        func parse(_ raw: String) -> Int? {
            do {
                _ = try HttpParser.readHead(Data(raw.utf8))
                return nil
            } catch let error as HttpError {
                return error.status
            } catch {
                return nil
            }
        }
        XCTAssertEqual(400, parse("GARBAGE\r\n\r\n"))
        XCTAssertEqual(400, parse("GET http://evil/ HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(400, parse("POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\n"))
        XCTAssertEqual(400, parse("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n"))
        XCTAssertEqual(411, parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))
        XCTAssertEqual(431, parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000) + "\r\n\r\n"))
        XCTAssertEqual(400, parse("GET / HTTP/1.1\r\n"))
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor AsyncCounter {
    var value = 0
    func increment() { value += 1 }
}

final class FolderUploadSinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "music"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFilesAppearOnlyWhenCompleteAndAreNeverOverwritten() throws {
        let music = root.appending(path: "music")
        let sink = FolderUploadSink(folder: music, staging: root.appending(path: "staging"))
        guard case .opened(let upload) = try sink.open("a.mp3", 5) else { return XCTFail("not opened") }
        try upload.write(Data("ID3ab".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: music.appending(path: "a.mp3").path))
        try upload.commit()
        XCTAssertEqual(Data("ID3ab".utf8), try Data(contentsOf: music.appending(path: "a.mp3")))
        XCTAssertEqual(.duplicate, sink.check("a.mp3", 5))
        XCTAssertEqual(.accept(savedName: "a (2).mp3"), sink.check("a.mp3", 6))
        guard case .opened(let aborted) = try sink.open("b.mp3", 5) else { return XCTFail("not opened") }
        try aborted.write(Data("ID3".utf8))
        aborted.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: music.appending(path: "b.mp3").path))
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "staging").path)) ?? []
        XCTAssertTrue(staged.isEmpty)
    }
}
