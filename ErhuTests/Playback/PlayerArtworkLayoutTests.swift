import SwiftUI
import UIKit
import XCTest
@testable import Erhu

final class PlayerArtworkLayoutTests: XCTestCase {
    /// Exercise the production modifiers: the artwork moves, its measuring slot and the controls
    /// stay fixed. Measuring the painted frame as the next source would feed motion back into itself.
    @MainActor
    func testOnlyArtworkTravelsAndItsUntransformedMeasurementStaysStable() async throws {
        let source = CGRect(x: 54, y: 85, width: 282, height: 282)
        let destination = CGRect(x: 20, y: 660, width: 44, height: 44)
        let controls = CGRect(x: 20, y: 410, width: 350, height: 100)
        let drag = PlayerDragState()
        drag.travel = 500
        drag.setPresented(true, reduceMotion: true)
        drag.finishEntrance(reduceMotion: true)
        var measuredFrames = PlayerArtworkFrames()
        var rendered = RenderFrames()
        let measured = expectation(description: "Artwork and controls laid out")
        measured.assertForOverFulfill = false
        let report: (PlayerArtworkFrames) -> Void = {
            measuredFrames = $0
            if $0.expanded.width > 0 && $0.mini.width > 0 { measured.fulfill() }
        }
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: Probe(drag: drag, source: source, destination: destination,
                                                             controls: controls, report: report, painted: { rendered = $0 }))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        await fulfillment(of: [measured], timeout: 3)
        for progress in [CGFloat(1), 0.7, 0.3, 0] {
            drag.update((1 - progress) * drag.travel)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            assertRect(measuredFrames.expanded, source)
            assertRect(measuredFrames.mini, destination)
            assertRect(rendered.controls, controls)
            let expected = source.applying(PlayerCoverGeometry.transform(progress: progress, source: source, destination: destination))
            assertRect(rendered.artwork, expected)
        }
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }

    private struct RenderFrames: Equatable {
        var artwork: CGRect = .zero
        var controls: CGRect = .zero
    }
    private struct RenderKey: PreferenceKey {
        static var defaultValue = RenderFrames()
        static func reduce(value: inout RenderFrames, nextValue: () -> RenderFrames) {
            let next = nextValue()
            if next.artwork.width > 0 { value.artwork = next.artwork }
            if next.controls.width > 0 { value.controls = next.controls }
        }
    }

    private struct Probe: View {
        let drag: PlayerDragState
        let source: CGRect
        let destination: CGRect
        let controls: CGRect
        let report: (PlayerArtworkFrames) -> Void
        let painted: (RenderFrames) -> Void

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: destination.width, height: destination.height)
                    .playerArtworkFrame(expanded: false)
                    .offset(x: destination.minX, y: destination.minY)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: source.width, height: source.height)
                        .playerArtworkFrame(expanded: true)
                        .offset(x: source.minX, y: source.minY)
                    Color.green
                        .frame(width: controls.width, height: controls.height)
                        .background { GeometryReader { proxy in
                            Color.clear.preference(key: RenderKey.self, value: RenderFrames(controls: proxy.frame(in: .named(PlayerArtworkSpace.root))))
                        } }
                        .offset(x: controls.minX, y: controls.minY)
                        .modifier(PlayerChromeFade())
                }
                .frame(width: 390, height: 780, alignment: .topLeading)
                .modifier(PlayerForegroundMotion(drag: drag))
                .overlay {
                    PlayerArtworkOverlay(progress: drag.progress, frames: PlayerArtworkFrames(expanded: source, mini: destination)) {
                        Color.blue
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key: RenderKey.self, value: RenderFrames(artwork: proxy.frame(in: .named(PlayerArtworkSpace.root))))
                            } }
                    }
                }
                .environment(drag)
                .environment(\.playerArtworkFrames, PlayerArtworkFrames(expanded: source, mini: destination))
            }
            .frame(width: 390, height: 780, alignment: .topLeading)
            .coordinateSpace(name: PlayerArtworkSpace.root)
            .onPreferenceChange(PlayerArtworkFrameKey.self, perform: report)
            .onPreferenceChange(RenderKey.self, perform: painted)
        }
    }
}
