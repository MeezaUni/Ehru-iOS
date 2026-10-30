import Foundation
import Network
import XCTest
@testable import Ehru

/// Real listening sockets and HTTP bytes: router-only tests cannot catch listener startup errors.
final class TransferNetworkTests: XCTestCase {
    private let clientQueue = DispatchQueue(label: "ehru.test.transfer.client")

    private func server(folder: URL, session: TransferSession) -> TransferServer {
        let sink = FolderUploadSink(folder: folder.appendingPathComponent("music"),
                                    staging: folder.appendingPathComponent("partial"))
        let registry = TransferRegistry()
        // Production accepts only Wi-Fi; the native test client connects over loopback.
        return TransferServer(address: "127.0.0.1", limits: TransferLimits(), allowsConnection: { _ in true }) { host in
            TransferRouter(session: session, hostPort: host, sink: sink, registry: registry)
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("music"), withIntermediateDirectories: true)
        return url
    }

    private func session() -> TransferSession { .create(nowMs: Int64(Date().timeIntervalSince1970 * 1000)) }

    func testListenerStartsAndBrowserCanPairUploadAndSkipADuplicate() async throws {
        let folder = try self.folder(), session = self.session()
        let server = self.server(folder: folder, session: session)
        defer { server.stop(); try? FileManager.default.removeItem(at: folder) }
        let port = try await server.start(preferredPort: 0)
        XCTAssertNotEqual(port, 0)
        let page = try await request(port: port, path: "/")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("empee3 Wi-Fi Transfer"))

        let pair = try await request(port: port, path: "/api/pair", method: "POST", headers: [
            TransferRouter.clientHeader: "1", TransferRouter.codeHeader: session.pairingCode,
        ])
        XCTAssertEqual(pair.status, 200)
        let paired = try XCTUnwrap(JSONSerialization.jsonObject(with: pair.body) as? [String: Any])
        let token = try XCTUnwrap(paired["token"] as? String)
        XCTAssertEqual(token, session.token)
        var audio = Data("ID3".utf8)
        audio.append(Data(count: 4093))
        let headers = [TransferRouter.clientHeader: "1", TransferRouter.tokenHeader: token,
                       TransferRouter.nameHeader: "network.mp3", "Content-Type": "application/octet-stream"]
        let upload = try await request(port: port, path: "/api/upload", method: "POST", headers: headers, body: audio)
        XCTAssertEqual(upload.status, 200)
        XCTAssertTrue(String(decoding: upload.body, as: UTF8.self).contains("saved"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("music/network.mp3")), audio)
        let duplicate = try await request(port: port, path: "/api/upload", method: "POST", headers: headers, body: audio)
        XCTAssertEqual(duplicate.status, 200)
        XCTAssertTrue(String(decoding: duplicate.body, as: UTF8.self).contains("duplicate"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("music").path), ["network.mp3"])

        let refused = try await request(port: port, path: "/api/upload", method: "POST",
                                        headers: [TransferRouter.clientHeader: "1", TransferRouter.nameHeader: "no-token.mp3"], body: audio)
        XCTAssertEqual(refused.status, 401)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("music/no-token.mp3").path))
    }

    func testOccupiedPortFallsBackAndReportsTheActualPort() async throws {
        let folder = try self.folder(), session = self.session()
        let first = server(folder: folder, session: session), second = server(folder: folder, session: session)
        defer { first.stop(); second.stop(); try? FileManager.default.removeItem(at: folder) }
        let occupied = try await first.start(preferredPort: 0)
        let fallback = try await second.start(preferredPort: occupied)
        XCTAssertNotEqual(fallback, occupied)
        let response = try await request(port: fallback, path: "/")
        XCTAssertEqual(response.status, 200, "Host validation must use the fallback socket's real port")
    }

    func testStoppedServerCannotStartAfterCancellation() async throws {
        let folder = try self.folder()
        let server = self.server(folder: folder, session: self.session())
        defer { server.stop(); try? FileManager.default.removeItem(at: folder) }
        server.stop()
        do {
            _ = try await server.start(preferredPort: 0)
            XCTFail("A cancelled startup must not open a new listener")
        } catch is CancellationError {} catch { XCTFail("Unexpected startup error: \(error)") }
    }

    @MainActor
    func testStopThenImmediateRestartCannotPublishAnOldStartup() async throws {
        let library = LibraryStore(database: try LibraryDatabase.inMemory())
        let store = WifiTransferStore(library: library, addressProvider: { "127.0.0.1" })
        defer { store.stop() }
        store.start()
        await Task.yield()
        store.stop(.backgrounded)
        XCTAssertEqual(store.state, .stopped(.backgrounded))
        store.start()
        let deadline = Date().addingTimeInterval(5)
        while store.state == .starting, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .running = store.state else { return XCTFail("The replacement session must start independently: \(store.state)") }
        try await Task.sleep(for: .milliseconds(100))
        guard case .running = store.state else { return XCTFail("The cancelled attempt must not stop its replacement") }
    }

    private func request(port: UInt16, path: String, method: String = "GET", headers: [String: String] = [:],
                         body: Data = Data()) async throws -> (status: Int, body: Data) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result = ConnectResult(continuation)
            let timeout = DispatchWorkItem {
                if result.finish(URLError(.timedOut)) { connection.cancel() }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: timeout.cancel(); _ = result.finish(nil)
                case .failed(let error), .waiting(let error): timeout.cancel(); _ = result.finish(error)
                case .cancelled: timeout.cancel(); _ = result.finish(CancellationError())
                default: break
                }
            }
            connection.start(queue: clientQueue)
            clientQueue.asyncAfter(deadline: .now() + 5, execute: timeout)
        }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        var bytes = Data((head + "\r\n").utf8)
        bytes.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        let reader = ConnectionReader(connection: connection, timeout: 5)
        var received = Data()
        while let chunk = await reader.read(max: 64 * 1024), !chunk.isEmpty { received.append(chunk) }
        let end = try XCTUnwrap(received.range(of: Data("\r\n\r\n".utf8)))
        let line = String(decoding: received[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")[0]
        let status = try XCTUnwrap(Int(line.components(separatedBy: " ").dropFirst().first ?? ""))
        return (status, Data(received[end.upperBound...]))
    }

    private final class ConnectResult: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ error: Error?) -> Bool {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { continuation = nil }
                return continuation
            }
            if let error { pending?.resume(throwing: error) } else { pending?.resume() }
            return pending != nil
        }
    }
}
