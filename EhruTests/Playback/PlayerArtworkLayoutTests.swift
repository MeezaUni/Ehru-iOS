import SwiftUI
import UIKit
import XCTest
@testable import Ehru

final class PlayerArtworkLayoutTests: XCTestCase {
    /// Measuring in the root after applying the transform would change this frame on every
    /// update, feeding the animation back into itself. Exercise the actual SwiftUI hierarchy.
    @MainActor
    func testExpandedArtworkMeasurementStaysStableWhileTheForegroundShrinks() async throws {
        let source = CGRect(x: 54, y: 85, width: 282, height: 282)
        let destination = CGRect(x: 20, y: 660, width: 44, height: 44)
        var frames = PlayerArtworkFrames()
        let measured = expectation(description: "Expanded and mini artwork laid out")
        measured.assertForOverFulfill = false
        let report: (PlayerArtworkFrames) -> Void = {
            frames = $0
            if $0.expanded.width > 0 && $0.mini.width > 0 { measured.fulfill() }
        }
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(rootView: Probe(progress: 1, source: source, destination: destination, report: report))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        await fulfillment(of: [measured], timeout: 3)
        for progress in [CGFloat(1), 0.7, 0.3, 0] {
            controller.rootView = Probe(progress: progress, source: source, destination: destination, report: report)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(frames.expanded.minX, source.minX, accuracy: 0.5)
            XCTAssertEqual(frames.expanded.minY, source.minY, accuracy: 0.5)
            XCTAssertEqual(frames.expanded.width, source.width, accuracy: 0.5)
            XCTAssertEqual(frames.expanded.height, source.height, accuracy: 0.5)
            XCTAssertEqual(frames.mini.minX, destination.minX, accuracy: 0.5)
            XCTAssertEqual(frames.mini.minY, destination.minY, accuracy: 0.5)
        }
    }

    private struct Probe: View {
        let progress: CGFloat
        let source: CGRect
        let destination: CGRect
        let report: (PlayerArtworkFrames) -> Void

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: destination.width, height: destination.height)
                    .playerArtworkFrame(expanded: false)
                    .offset(x: destination.minX, y: destination.minY)
                Color.blue
                    .frame(width: source.width, height: source.height)
                    .playerArtworkFrame(expanded: true)
                    .padding(.leading, source.minX).padding(.top, source.minY)
                    .frame(width: 390, height: 780, alignment: .topLeading)
                    .coordinateSpace(name: PlayerArtworkSpace.expanded)
                    .modifier(PlayerCoverTransform(progress: progress, source: source, destination: destination))
            }
            .frame(width: 390, height: 780, alignment: .topLeading)
            .coordinateSpace(name: PlayerArtworkSpace.root)
            .onPreferenceChange(PlayerArtworkFrameKey.self, perform: report)
        }
    }
}
