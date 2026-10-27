import Foundation
import Network

/// A small HTTP server for one transfer session, listening only on the Wi-Fi address (never on
/// every interface). One request per connection; at most [TransferLimits.maxConnections] at once
/// (others get a quick 503); stalled connections time out. [stop] closes the listener and every
/// connection, which ends any upload in progress (the router then deletes its partial file).
final class TransferServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 8770

    private let address: String
    private let limits: TransferLimits
    private let routerFor: (String) -> TransferRouter
    private let queue = DispatchQueue(label: "ehru.transfer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()

    init(address: String, limits: TransferLimits, routerFor: @escaping (String) -> TransferRouter) {
        self.address = address
        self.limits = limits
        self.routerFor = routerFor
    }

    /// Starts listening on [preferredPort] (or a free port if it is taken). Returns the port in use.
    func start(preferredPort: UInt16 = defaultPort) async throws -> UInt16 {
        do {
            return try await listen(on: preferredPort)
        } catch {
            return try await listen(on: 0)
        }
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed, let port = listener.port?.rawValue {
                        resumed = true
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                    listener.cancel()
                case .cancelled:
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
                _ = self
            }
            listener.start(queue: queue)
        }
        let router = routerFor("\(address):\(bound)")
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, router) }
        lock.withLock { self.listener = listener }
        return bound
    }

    func stop() {
        let (listener, open) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            defer {
                self.listener = nil
                connections = [:]
            }
            return (self.listener, Array(connections.values))
        }
        listener?.cancel()
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection, _ router: TransferRouter) {
        let admitted = lock.withLock { () -> Bool in
            guard connections.count < limits.maxConnections else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        connection.start(queue: queue)
        guard admitted else {
            sendAndClose(HttpResponse.error(HttpStatus.serviceUnavailable, "Too many connections, try again"), on: connection)
            return
        }
        let reader = ConnectionReader(connection: connection, timeout: limits.readTimeoutSeconds)
        Task {
            let response: HttpResponse?
            do {
                let request = try await reader.readHead()
                response = await router.handle(request, body: reader)
            } catch let error as HttpError {
                response = .error(error.status, error.message)
            } catch {
                response = nil
            }
            if let response { await send(response, on: connection) } else { connection.cancel() }
            lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
        }
    }

    private func sendAndClose(_ response: HttpResponse, on connection: NWConnection) {
        connection.send(content: response.bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ response: HttpResponse, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: response.bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }
}

/// Reads one request from a connection: the bounded head, then the body on demand, each read
/// giving up after the read timeout.
final class ConnectionReader: BodyReader, @unchecked Sendable {
    private let connection: NWConnection
    private let timeout: Double
    private var buffered = Data()

    init(connection: NWConnection, timeout: Double) {
        self.connection = connection
        self.timeout = timeout
    }

    func readHead() async throws -> HttpRequest {
        while true {
            if let end = HttpParser.headEnd(in: buffered) {
                if end > HttpParser.maxHeadBytes { throw HttpError(status: HttpStatus.headersTooLarge, message: "Request head too large") }
                let head = buffered.prefix(end - 4)
                buffered = Data(buffered.dropFirst(end))
                return try HttpParser.parse(head: Data(head))
            }
            if buffered.count > HttpParser.maxHeadBytes { throw HttpError(status: HttpStatus.headersTooLarge, message: "Request head too large") }
            guard let chunk = await receive(max: 8 * 1024), !chunk.isEmpty else {
                throw HttpError(status: HttpStatus.badRequest, message: "Incomplete request")
            }
            buffered.append(chunk)
        }
    }

    func read(max: Int) async -> Data? {
        if !buffered.isEmpty {
            let part = buffered.prefix(max)
            buffered = Data(buffered.dropFirst(part.count))
            return Data(part)
        }
        return await receive(max: max)
    }

    private func receive(max: Int) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let state = ResumeOnce(continuation)
            let timer = DispatchWorkItem { [connection] in
                // Stalled past the read timeout: the connection is dropped.
                if state.resume(nil) { connection.cancel() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                timer.cancel()
                if let data, !data.isEmpty {
                    _ = state.resume(data)
                } else {
                    _ = state.resume(nil)
                }
            }
        }
    }

    /// Resumes a continuation once, whichever of the read and the timeout comes first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?

        init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

        func resume(_ value: Data?) -> Bool {
            let pending = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
            return pending != nil
        }
    }
}

/// The phone's IPv4 address on Wi-Fi (en0), or nil without Wi-Fi.
func wifiAddress() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
    defer { freeifaddrs(addresses) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        defer { pointer = current.pointee.ifa_next }
        let interface = current.pointee
        guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0",
              (Int32(interface.ifa_flags) & IFF_UP) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let text = String(cString: host)
        if !text.hasPrefix("169.254.") && text != "127.0.0.1" { return text }
    }
    return nil
}
