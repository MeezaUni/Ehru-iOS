import Observation
import SwiftUI

private struct PlayerCoverProgressKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct PlayerMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var playerCoverProgress: CGFloat {
        get { self[PlayerCoverProgressKey.self] }
        set { self[PlayerCoverProgressKey.self] = newValue }
    }
    var playerInMotion: Bool {
        get { self[PlayerMotionKey.self] }
        set { self[PlayerMotionKey.self] = newValue }
    }
}

enum PlayerArtworkSpace {
    static let root = "player.root"
    static let expanded = "player.expanded"
}

struct PlayerArtworkFrames: Equatable {
    var expanded: CGRect = .zero
    var mini: CGRect = .zero
}

struct PlayerArtworkFrameKey: PreferenceKey {
    static var defaultValue = PlayerArtworkFrames()
    static func reduce(value: inout PlayerArtworkFrames, nextValue: () -> PlayerArtworkFrames) {
        let next = nextValue()
        if next.expanded.width > 0 { value.expanded = next.expanded }
        if next.mini.width > 0 { value.mini = next.mini }
    }
}

extension View {
    func playerArtworkFrame(expanded: Bool) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: PlayerArtworkFrameKey.self,
                    value: expanded
                        ? PlayerArtworkFrames(expanded: geometry.frame(in: .named(PlayerArtworkSpace.expanded)))
                        : PlayerArtworkFrames(mini: geometry.frame(in: .named(PlayerArtworkSpace.root))))
            }
        }
    }
}

/// Only lightweight modifiers observe progress. The actual cover stays mounted throughout;
/// no second video, screen snapshot, or artwork decode is created for the animation.
struct PlayerPresentation: View {
    let drag: PlayerDragState
    let frames: PlayerArtworkFrames
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedEntrance = false

    var body: some View {
        NowPlayingView(drag: drag)
            .environment(\.playerInMotion, drag.isMoving)
            .environment(\.playerArtworkFrames, frames)
            .opacity(frames.expanded.width > 0 ? 1 : 0)
            .onChange(of: frames.expanded, initial: true) { _, frame in
                guard frame.width > 0, !startedEntrance else { return }
                startedEntrance = true
                drag.finishEntrance(reduceMotion: reduceMotion)
            }
    }
}

private struct PlayerArtworkFramesKey: EnvironmentKey { static let defaultValue = PlayerArtworkFrames() }
extension EnvironmentValues {
    var playerArtworkFrames: PlayerArtworkFrames {
        get { self[PlayerArtworkFramesKey.self] }
        set { self[PlayerArtworkFramesKey.self] = newValue }
    }
}

/// Keeps the expanded artwork's centre and size on the path to the real mini-player artwork.
/// The named expanded coordinate space is inside this transform, so measuring never feeds
/// the transformed frame back into the next animation frame.
struct PlayerForegroundMotion: ViewModifier {
    let drag: PlayerDragState
    @Environment(\.playerArtworkFrames) private var frames
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.playerCoverProgress, drag.progress)
            .coordinateSpace(name: PlayerArtworkSpace.expanded)
            .modifier(PlayerCoverTransform(progress: reduceMotion ? 1 : drag.progress,
                                           source: frames.expanded, destination: frames.mini))
            .opacity(reduceMotion ? Double(drag.progress) : 1)
    }
}

struct PlayerCoverTransform: GeometryEffect {
    var progress: CGFloat
    let source: CGRect
    let destination: CGRect
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(PlayerCoverGeometry.transform(progress: progress, source: source, destination: destination))
    }
}

enum PlayerCoverGeometry {
    static func transform(progress: CGFloat, source: CGRect, destination: CGRect) -> CGAffineTransform {
        guard progress.isFinite, source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else { return .identity }
        let p = progress.clamped(0, 1)
        let small = destination.width / source.width
        let scale = small + (1 - small) * p
        let x = destination.midX + (source.midX - destination.midX) * p
        let y = destination.midY + (source.midY - destination.midY) * p
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: x - source.midX * scale, ty: y - source.midY * scale)
    }

    static func chromeOpacity(_ progress: CGFloat) -> Double { Double(((progress - 0.45) / 0.55).clamped(0, 1)) }
}

/// Header, controls, neighbours and card chrome disappear before the cover reaches the bar.
struct PlayerChromeFade: ViewModifier {
    @Environment(PlayerDragState.self) private var drag
    func body(content: Content) -> some View {
        content.opacity(PlayerCoverGeometry.chromeOpacity(drag.progress))
    }
}

/// Compensate the artwork's local corner radius for the shrinking foreground scale.
struct PlayerArtworkClip: ViewModifier {
    let isCurrent: Bool
    let side: CGFloat
    @Environment(PlayerDragState.self) private var drag
    @Environment(\.playerArtworkFrames) private var frames
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let small = frames.mini.width / max(side, 1)
        let targetRadius = small > 0 ? Radius.small / small : Radius.large
        let progress = isCurrent && !reduceMotion ? drag.progress : 1
        let radius = targetRadius + (Radius.large - targetRadius) * progress
        content.clipShape(RoundedRectangle(cornerRadius: min(radius, side / 2), style: .continuous))
    }
}

struct PlayerBackdropFade: ViewModifier {
    let drag: PlayerDragState
    func body(content: Content) -> some View { content.opacity(Double(drag.progress)) }
}

struct MiniArtworkVisibility: ViewModifier {
    @Environment(PlayerDragState.self) private var drag
    func body(content: Content) -> some View { content.opacity(drag.isPresented && drag.isReady ? 0 : 1) }
}

@MainActor
@Observable
final class PlayerDragState {
    private(set) var translation: CGFloat = 0
    private(set) var progress: CGFloat = 1
    private(set) var isPresented = false
    private(set) var isReady = false
    private(set) var isMoving = true
    @ObservationIgnored private var animationID = UUID()
    @ObservationIgnored private var wantsPresented = false
    @ObservationIgnored var travel: CGFloat = 500

    func setPresented(_ presented: Bool, reduceMotion: Bool) {
        wantsPresented = presented
        if presented && !isPresented {
            animationID = UUID()
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) {
                progress = 0
                translation = 0
                isMoving = true
                isReady = false
                isPresented = true
            }
            // The measured expanded artwork starts the entrance after both endpoints are mounted.
        } else {
            animate(to: presented ? 1 : 0, reduceMotion: reduceMotion)
        }
    }

    func update(_ distance: CGFloat) {
        guard distance.isFinite else { return }
        animationID = UUID()
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) {
            isMoving = true
            translation = max(distance, 0)
            progress = (1 - translation / max(travel, 1)).clamped(0, 1)
        }
    }

    func finishEntrance(reduceMotion: Bool = false) {
        guard wantsPresented else { return }
        isReady = true
        animate(to: 1, reduceMotion: reduceMotion)
    }
    func beginDismissal() { animationID = UUID(); isMoving = true }
    func restore(reduceMotion: Bool = false) { animate(to: 1, reduceMotion: reduceMotion) }

    private func animate(to target: CGFloat, reduceMotion: Bool) {
        let id = UUID(); animationID = id
        isMoving = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.36), completionCriteria: .removed) {
            translation = 0
            progress = target
        } completion: { [weak self] in
            guard let self, self.animationID == id else { return }
            self.isMoving = false
            if target == 0 && !self.wantsPresented { self.isPresented = false }
        }
    }
}
