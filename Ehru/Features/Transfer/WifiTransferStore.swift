import Foundation
import Observation
import UIKit

/// Why a session is not running (nil: never started).
enum StopReason: Equatable {
    case user, noWifi, wifiLost, idleTimeout, sessionExpired, backgrounded, failedToStart
}

enum TransferServerState: Equatable {
    case stopped(StopReason?)
    case starting
    /// Listening: only reported once the socket is really bound.
    case running(address: String, pairingUrl: String, pairingCode: String)
}

/// One Wi-Fi transfer session at a time, from the user's Start to Stop (Android's
/// WifiTransferCoordinator). The server listens only on the Wi-Fi address and only while the app
/// is open (iOS suspends it in the background): it stops when the user stops it, when Wi-Fi goes
/// away or changes address, after 10 minutes without any request, when the session's lifetime ends,
/// or when the app leaves the foreground. Every stop closes the session (its credentials stop
/// working), every connection, and deletes partial files. Saved files are picked up by a rescan.
@MainActor
@Observable
final class WifiTransferStore {
    /// Stop after this long without any request from the computer (no upload running).
    static let idleTimeoutMs: Int64 = 10 * 60 * 1000
    private static let watchdogInterval: Duration = .seconds(15)
    /// One rescan after a batch of files, not one per file.
    private static let quietPeriod: Duration = .seconds(4)

    private(set) var state: TransferServerState = .stopped(nil)
    private(set) var items: [TransferItem] = []

    private let library: LibraryStore
    @ObservationIgnored private let registry = TransferRegistry()
    @ObservationIgnored private let limits = TransferLimits()
    @ObservationIgnored private var server: TransferServer?
    @ObservationIgnored private var session: TransferSession?
    @ObservationIgnored private var sink: FolderUploadSink?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private let activity = ActivityClock()

    init(library: LibraryStore) {
        self.library = library
        registry.onChange = { [weak self] items in
            Task { @MainActor in self?.items = items }
        }
    }

    var counts: (saved: Int, duplicates: Int, failed: Int) {
        (items.filter { $0.status == .completed }.count, items.filter { $0.status == .duplicate }.count,
         items.filter { $0.status == .failed || $0.status == .cancelled }.count)
    }

    func start() {
        switch state {
        case .running, .starting: return
        case .stopped: break
        }
        guard let address = wifiAddress() else {
            state = .stopped(.noWifi)
            return
        }
        state = .starting
        let now = Self.now()
        let newSession = TransferSession.create(nowMs: now)
        let newSink = FolderUploadSink()
        registry.clear()
        let registry = registry
        let limits = limits
        let activity = activity
        let events = TransferEvents(
            onRequest: { activity.touch() },
            onUploadStarted: { activity.uploadStarted() },
            onUploadFinished: { activity.uploadFinished() },
            onFileSaved: { [weak self] in Task { @MainActor in self?.fileSaved() } }
        )
        let newServer = TransferServer(address: address, limits: limits) { hostPort in
            TransferRouter(session: newSession, hostPort: hostPort, sink: newSink, registry: registry, limits: limits, events: events)
        }
        Task {
            newSink.cleanUpLeftovers()
            do {
                let port = try await newServer.start()
                guard state == .starting else {
                    newServer.stop()
                    return
                }
                session = newSession
                server = newServer
                sink = newSink
                activity.touch()
                startWatchdog(newSession, address: address)
                UIApplication.shared.isIdleTimerDisabled = true
                let base = "http://\(address):\(port)"
                state = .running(address: base, pairingUrl: "\(base)/#t=\(newSession.token)", pairingCode: newSession.pairingCode)
            } catch {
                newServer.stop()
                finish(.failedToStart)
            }
        }
    }

    func stop(_ reason: StopReason = .user) {
        if case .stopped = state { return }
        finish(reason)
    }

    private func finish(_ reason: StopReason) {
        watchdog?.cancel()
        watchdog = nil
        session?.close()
        session = nil
        server?.stop()
        server = nil
        registry.cancelAllActive()
        sink?.cleanUpLeftovers()
        sink = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if refresh != nil {
            refresh?.cancel()
            refresh = nil
            library.scan()
        }
        state = .stopped(reason)
    }

    private func fileSaved() {
        refresh?.cancel()
        let activity = activity
        refresh = Task {
            try? await Task.sleep(for: Self.quietPeriod)
            while !Task.isCancelled, activity.uploading > 0 { try? await Task.sleep(for: Self.quietPeriod) }
            if Task.isCancelled { return }
            refresh = nil
            library.scan()
        }
    }

    private func startWatchdog(_ current: TransferSession, address: String) {
        watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                if Task.isCancelled { return }
                let now = Self.now()
                if !current.isOpen(now) {
                    stop(.sessionExpired)
                } else if activity.uploading == 0, now - activity.lastActivity > Self.idleTimeoutMs {
                    stop(.idleTimeout)
                } else if wifiAddress() != address {
                    stop(.wifiLost)
                }
            }
        }
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// Request activity and running uploads, updated from the server's threads.
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    private var active = 0

    var lastActivity: Int64 { lock.withLock { last } }
    var uploading: Int { lock.withLock { active } }

    func touch() { lock.withLock { last = Int64(Date().timeIntervalSince1970 * 1000) } }
    func uploadStarted() { lock.withLock { active += 1 } }
    func uploadFinished() { lock.withLock { active -= 1 } }
}
