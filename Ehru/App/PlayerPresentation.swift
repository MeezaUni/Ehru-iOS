import Observation
import SwiftUI

private struct PlayerCoverProgressKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct PlayerArtworkInFlightKey: EnvironmentKey { static let defaultValue = false }
private struct PlayerMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var playerArtworkInFlight: Bool {
        get { self[PlayerArtworkInFlightKey.self] }
        set { self[PlayerArtworkInFlightKey.self] = newValue }
    }
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

/// The player stays in place. Only its current artwork is allowed to fly to the mini-player.
/// Keeping this named space outside the art slot lets an untransformed placeholder measure it.
struct PlayerForegroundMotion: ViewModifier {
    let drag: PlayerDragState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.playerCoverProgress, drag.progress)
            .environment(\.playerArtworkInFlight, drag.isMoving && drag.isReady && !reduceMotion)
            .coordinateSpace(name: PlayerArtworkSpace.expanded)
            .opacity(reduceMotion ? Double(drag.progress) : 1)
    }
}

/// A sibling of the scrolling foreground, so the moving artwork cannot be cropped by the
/// carousel's projection surface or the ScrollView. Production and rendered-image tests use it.
struct PlayerArtworkOverlay<Artwork: View>: View {
    let progress: CGFloat
    let frames: PlayerArtworkFrames
    var visible = true
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        GeometryReader { _ in
            artwork()
                .frame(width: frames.expanded.width, height: frames.expanded.height)
                .modifier(PlayerArtworkTransform(progress: progress, source: frames.expanded, destination: frames.mini, visible: visible))
                .position(x: frames.expanded.midX, y: frames.expanded.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PlayerArtworkTransform: GeometryEffect {
    var progress: CGFloat
    let source: CGRect
    let destination: CGRect
    var visible = true
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(visible ? PlayerCoverGeometry.artworkTransform(progress: progress, source: source, destination: destination)
                            : CGAffineTransform(translationX: -10_000, y: 0))
    }
}

/// Visibility is discrete, while the flight's progress animates. Opacity interpolation would
/// briefly show two covers (or neither) when handing ownership to the overlay.
struct PlayerArtworkSlotVisibility: GeometryEffect {
    let hidden: Bool
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(hidden ? CGAffineTransform(translationX: -10_000, y: 0) : .identity)
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

    /// An artwork view has its own local origin; conjugate the root-space transform so its
    /// placeholder remains fixed while the painted pixels travel to the measured destination.
    static func artworkTransform(progress: CGFloat, source: CGRect, destination: CGRect) -> CGAffineTransform {
        let root = transform(progress: progress, source: source, destination: destination)
        return CGAffineTransform(translationX: source.minX, y: source.minY)
            .concatenating(root)
            .concatenating(CGAffineTransform(translationX: -source.minX, y: -source.minY))
    }

    static func chromeOpacity(_ progress: CGFloat) -> Double {
        let p = progress.clamped(0, 1)
        return Double(p * p * (3 - 2 * p))
    }
}

/// Chrome joins the cover's motion, rather than waiting for an all-or-nothing completion flag.
struct PlayerChromeFade: ViewModifier {
    @Environment(PlayerDragState.self) private var drag
    func body(content: Content) -> some View {
        content.modifier(PlayerChromeOpacity(progress: drag.progress))
            .modifier(PlayerCollapseVisibility())
    }
}

/// Collapse has a single painted owner: the floating artwork. Hide the remaining paint
/// immediately while retaining its layout, measurement and active drag recognizer.
struct PlayerCollapseVisibility: ViewModifier {
    @Environment(PlayerDragState.self) private var drag
    func body(content: Content) -> some View {
        content.opacity(drag.isCollapsing ? 0 : 1)
            .transaction { if drag.isCollapsing { $0.animation = nil } }
    }
}

struct PlayerChromeOpacity: AnimatableModifier {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View { content.opacity(PlayerCoverGeometry.chromeOpacity(progress)) }
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
    func body(content: Content) -> some View {
        content.opacity(Double(drag.progress)).modifier(PlayerCollapseVisibility())
    }
}

struct MiniArtworkVisibility: ViewModifier {
    @Environment(PlayerDragState.self) private var drag
    func body(content: Content) -> some View { content.opacity(drag.isPresented && drag.isReady ? 0 : 1) }
}

enum PlayerMotionTiming {
    static let duration: TimeInterval = 0.40
    static func presentation(reduceMotion: Bool) -> Animation {
        .timingCurve(0.25, 0.1, 0.25, 1, duration: reduceMotion ? 0.16 : duration)
    }
}

@MainActor
@Observable
final class PlayerDragState {
    private(set) var translation: CGFloat = 0
    private(set) var progress: CGFloat = 1
    private(set) var isPresented = false
    private(set) var isReady = false
    private(set) var isMoving = true
    private(set) var isCollapsing = false
    @ObservationIgnored private var animationID = UUID()
    @ObservationIgnored private var settlement: Task<Void, Never>?
    @ObservationIgnored private var wantsPresented = false
    @ObservationIgnored var travel: CGFloat = 500

    func setPresented(_ presented: Bool, reduceMotion: Bool) {
        wantsPresented = presented
        isCollapsing = !presented
        if presented && !isPresented {
            settlement?.cancel(); settlement = nil
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
        settlement?.cancel(); settlement = nil
        animationID = UUID()
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) {
            isMoving = true
            isCollapsing = distance > 0
            translation = max(distance, 0)
            progress = (1 - translation / max(travel, 1)).clamped(0, 1)
        }
    }

    func finishEntrance(reduceMotion: Bool = false) {
        guard wantsPresented else { return }
        isReady = true
        animate(to: 1, reduceMotion: reduceMotion)
    }
    func beginDismissal() { settlement?.cancel(); settlement = nil; animationID = UUID(); isMoving = true; isCollapsing = true }
    func restore(reduceMotion: Bool = false) { isCollapsing = false; animate(to: 1, reduceMotion: reduceMotion) }

    private func animate(to target: CGFloat, reduceMotion: Bool) {
        settlement?.cancel()
        let id = UUID(); animationID = id
        withAnimation(PlayerMotionTiming.presentation(reduceMotion: reduceMotion)) {
            isMoving = true
            translation = 0
            progress = target
        }
        let duration = reduceMotion ? 0.16 : PlayerMotionTiming.duration
        settlement = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.animationID == id, !Task.isCancelled else { return }
            self.settlement = nil
            self.isMoving = false
            if target == 0 && !self.wantsPresented { self.isPresented = false }
        }
    }
}
