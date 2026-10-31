import Observation
import SwiftUI

/// Scroll changes only this small object, observed by the chrome rather than the library tree.
@MainActor
@Observable
final class LibraryChromeState {
    private(set) var fraction: CGFloat = 0
    static let collapseDistance: CGFloat = 120

    func consume(_ delta: CGFloat) {
        guard delta.isFinite, delta != 0 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            fraction = (fraction + delta / Self.collapseDistance).clamped(0, 1)
        }
    }

    func settle(reduceMotion: Bool = false) { move(to: fraction > 0.5 ? 1 : 0, reduceMotion: reduceMotion) }
    func expand(reduceMotion: Bool = false) { move(to: 0, reduceMotion: reduceMotion) }

    private func move(to target: CGFloat, reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { fraction = target }
    }
}

extension View {
    /// Attach to the outer vertical scroll view, never a horizontal album shelf.
    func tracksLibraryScrolling() -> some View { modifier(LibraryScrollTracking()) }
}

/// Only tab roots consume reselects. Nested shelves keep their independent scroll positions.
struct LibraryRootScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(AppRouter.self) private var router
    @Environment(\.artworkSection) private var section
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let top = "library-root-top"

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1).id(top)
                    content
                }
            }
            .onChange(of: section.flatMap { router.scrollToTopRequests[$0] } ?? 0) { _, _ in
                guard section == router.section, router.paths[router.section]?.isEmpty ?? true else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(top, anchor: .top) }
            }
        }
    }
}

private struct LibraryScrollTracking: ViewModifier {
    @Environment(LibraryChromeState.self) private var chrome
    @Environment(AppRouter.self) private var router
    @Environment(\.artworkSection) private var section
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var userScrolling = false
    @State private var lastDrag: CGFloat = 0

    private var active: Bool { visible && section == router.section && !router.showsNowPlaying && !router.showsSearch }

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 18.0, *) {
                content
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        let end = max(geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height, 0)
                        // Rubber-banding at either end must not open/close the chrome.
                        return (geometry.contentOffset.y + geometry.contentInsets.top).clamped(0, end)
                    } action: { old, new in
                        if active && userScrolling { chrome.consume(new - old) }
                    }
                    .onScrollPhaseChange { _, phase in
                        userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                        if active && phase == .idle { chrome.settle(reduceMotion: reduceMotion) }
                    }
            } else {
                content.simultaneousGesture(DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard active, abs(value.translation.height) > abs(value.translation.width) else { return }
                        chrome.consume(lastDrag - value.translation.height)
                        lastDrag = value.translation.height
                    }
                    .onEnded { _ in
                        lastDrag = 0
                        if active { chrome.settle(reduceMotion: reduceMotion) }
                    })
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; userScrolling = false; lastDrag = 0 }
    }
}
