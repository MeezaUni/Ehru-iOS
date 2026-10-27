import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays the queue with AVPlayer, keeps playing in the background, and drives the lock screen /
/// Control Center controls.
@MainActor
@Observable
final class PlayerController {
    private(set) var queue = PlaybackQueue<Song>()
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var currentSong: Song? { queue.current }
    var repeatMode: RepeatMode { queue.repeatMode }
    var isShuffled: Bool { queue.isShuffled }

    private let player = AVPlayer()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?

    /// Pressing previous after this many seconds restarts the song instead.
    private static let restartThreshold: TimeInterval = 3

    init() {
        configureRemoteCommands()
        observeTime()
        observeAudioSession()
    }

    // MARK: Controls

    func play(_ songs: [Song], startingAt index: Int) {
        queue.load(songs, startingAt: index)
        startCurrentSong()
    }

    func shuffleAll(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        queue.load(songs, startingAt: Int.random(in: songs.indices))
        queue.setShuffled(true)
        startCurrentSong()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard currentSong != nil else { return }
        activateAudioSession()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func next() {
        if queue.skipForward() != nil {
            startCurrentSong()
        } else {
            stopAtEnd()
        }
    }

    func previous() {
        if currentTime > Self.restartThreshold {
            seek(to: 0)
        } else if queue.skipBackward() != nil {
            startCurrentSong()
        }
    }

    func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateNowPlayingInfo()
    }

    func cycleRepeatMode() {
        queue.repeatMode = queue.repeatMode.next
    }

    func toggleShuffle() {
        queue.setShuffled(!queue.isShuffled)
    }

    // MARK: Playback

    private func startCurrentSong() {
        guard let song = currentSong else { return }
        let item = AVPlayerItem(url: song.url)
        observeEnd(of: item)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = song.duration
        artwork = nil
        activateAudioSession()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        loadArtwork(for: song)
    }

    private func handleSongEnded() {
        if queue.advanceAfterCompletion() != nil {
            startCurrentSong()
        } else {
            stopAtEnd()
        }
    }

    private func stopAtEnd() {
        player.pause()
        player.seek(to: .zero)
        isPlaying = false
        currentTime = 0
        updateNowPlayingInfo()
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    // MARK: Observation

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSongEnded() }
        }
    }

    private func observeTime() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = time.seconds
                if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        })

        // Unplugging headphones pauses AVPlayer on its own; keep our state in step with it.
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
            }
        })
    }

    private func handleInterruption(type: UInt?, options: UInt?) {
        guard let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch interruption {
        case .began:
            isPlaying = false
            updateNowPlayingInfo()
        case .ended:
            if AVAudioSession.InterruptionOptions(rawValue: options ?? 0).contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    // MARK: Lock screen

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func loadArtwork(for song: Song) {
        Task {
            guard let data = await SongMetadata.artworkData(for: song.url),
                  let image = UIImage(data: data),
                  currentSong?.id == song.id
            else { return }
            artwork = Self.makeArtwork(image)
            updateNowPlayingInfo()
        }
    }

    /// Nonisolated because the system calls the image handler off the main thread.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
