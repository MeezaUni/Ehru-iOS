import XCTest
import SwiftUI
import UIKit
@testable import Erhu

final class LibraryChromeTests: XCTestCase {
    @MainActor
    func testArtistPageUsesItsPhotoWhileNowPlayingUsesTheSongCover() {
        let router = AppRouter()
        let photo = URL(fileURLWithPath: "/artist-photo.jpg")
        let song = URL(fileURLWithPath: "/playing.mp3")
        router.section = .library
        router.artworkFocus = (.library, .image(photo))
        XCTAssertEqual(router.paletteSource(playingSongURL: song), .image(photo))
        router.showsNowPlaying = true
        XCTAssertEqual(router.paletteSource(playingSongURL: song), .track(song))
        router.showsNowPlaying = false
        XCTAssertEqual(router.paletteSource(playingSongURL: song), .image(photo))
        router.artworkFocus = (.library, .image(nil))
        XCTAssertEqual(router.paletteSource(playingSongURL: song), .image(nil), "A missing artist photo must not borrow another artist's colours")
        router.select(.albums)
        XCTAssertEqual(router.paletteSource(playingSongURL: song), .track(song))
    }

    @MainActor
    func testTabsOpenTheirRootsInsteadOfRestoringTools() {
        let router = AppRouter()
        router.open(.settings)
        router.select(.albums)
        router.open(.artworkFetcher)
        router.select(.home)
        XCTAssertEqual(router.section, .home)
        XCTAssertTrue(router.paths[.home]!.isEmpty)
        router.select(.albums)
        XCTAssertTrue(router.paths[.albums]!.isEmpty)
    }

    @MainActor
    func testRepeatedTabTapsRequestScrollToTopForEverySection() {
        let router = AppRouter()
        for section in LibrarySection.allCases {
            router.select(section)
            let before = router.scrollToTopRequests[section, default: 0]
            router.select(section)
            router.select(section)
            XCTAssertEqual(router.scrollToTopRequests[section], before + 2)
            XCTAssertTrue(router.paths[section]!.isEmpty)
        }
        router.artworkFocus = (.home, .track(URL(fileURLWithPath: "/old-album.mp3")))
        router.select(.home)
        XCTAssertNil(router.focusedArtwork)
    }

    @MainActor
    func testReselectingATabActuallyScrollsItsMountedRootToTheTop() async throws {
        let router = AppRouter()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
        let host = UIHostingController(rootView: LibraryRootScrollView {
            LazyVStack { ForEach(0..<100) { Text("Track \($0)").frame(height: 44) } }
        }.environment(router).environment(\.artworkSection, .home))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        func scrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        for _ in 0..<150 {
            if let scroll = scrollView(host.view), scroll.contentSize.height > 2_000 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scroll = try XCTUnwrap(scrollView(host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: 800), animated: false)
        XCTAssertGreaterThan(scroll.contentOffset.y, 500)
        router.select(.home)
        for _ in 0..<150 {
            if scroll.contentOffset.y + scroll.adjustedContentInset.top < 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertLessThan(scroll.contentOffset.y + scroll.adjustedContentInset.top, 1)
    }

    @MainActor
    func testScrollingCompactsAndReversingScrollExpandsWithoutOvershooting() {
        let chrome = LibraryChromeState()
        chrome.consume(60)
        XCTAssertEqual(chrome.fraction, 0.5)
        chrome.consume(1_000)
        XCTAssertEqual(chrome.fraction, 1)
        chrome.consume(-30)
        XCTAssertEqual(chrome.fraction, 0.75)
        chrome.settle(reduceMotion: true)
        XCTAssertEqual(chrome.fraction, 1)
        chrome.consume(-90)
        chrome.settle(reduceMotion: true)
        XCTAssertEqual(chrome.fraction, 0)
        chrome.consume(.infinity)
        chrome.consume(.nan)
        XCTAssertEqual(chrome.fraction, 0)
        chrome.consume(120)
        chrome.expand(reduceMotion: true)
        XCTAssertEqual(chrome.fraction, 0)
    }

    func testCompactLayoutPreservesTouchTargetsAndFitsNarrowPhones() {
        for width in [CGFloat(296), 351, 366, 404] {
            let layout = LibraryChromeGeometry(width: width, fraction: 1, hasSong: true)
            XCTAssertEqual(layout.height, 60)
            XCTAssertEqual(layout.navigation.size, CGSize(width: 56, height: 56))
            XCTAssertEqual(layout.search.size, CGSize(width: 56, height: 56))
            XCTAssertEqual(layout.mini.minX - layout.navigation.maxX, 8)
            XCTAssertEqual(layout.search.minX - layout.mini.maxX, 8)
            XCTAssertEqual(layout.search.maxX, width)
            XCTAssertEqual(layout.mini.midY, layout.navigation.midY)
            XCTAssertGreaterThanOrEqual(layout.mini.width, 168)
        }
    }

    func testExpandedAndNoSongLayoutsKeepControlsInSeparateRows() {
        let layout = LibraryChromeGeometry(width: 366, fraction: 0, hasSong: true)
        XCTAssertEqual(layout.mini.width, 366)
        XCTAssertEqual(layout.navigation.minY - layout.mini.maxY, 8)
        XCTAssertEqual(layout.height, layout.navigation.maxY)
        let empty = LibraryChromeGeometry(width: 366, fraction: 1, hasSong: false)
        XCTAssertEqual(empty.height, 56)
        XCTAssertEqual(empty.mini.height, 0)
        XCTAssertEqual(empty.navigation.minY, 0)
        XCTAssertEqual(empty.navigation.width, 302)
    }

    func testDraggingCapsuleMapsToNearestSectionAndClampsAtBothEnds() {
        for index in 0..<4 {
            let center = CGFloat(44 + index * 80)
            XCTAssertEqual(SectionCapsuleGeometry.position(at: center, width: 328, count: 4), CGFloat(index))
            XCTAssertEqual(SectionCapsuleGeometry.index(at: center, width: 328, count: 4), index)
        }
        XCTAssertEqual(SectionCapsuleGeometry.index(at: 83, width: 328, count: 4), 0)
        XCTAssertEqual(SectionCapsuleGeometry.index(at: 85, width: 328, count: 4), 1)
        XCTAssertEqual(SectionCapsuleGeometry.index(at: -100, width: 328, count: 4), 0)
        XCTAssertEqual(SectionCapsuleGeometry.index(at: 900, width: 328, count: 4), 3)
        XCTAssertEqual(SectionCapsuleGeometry.index(at: 10, width: 0, count: 4), 0)
    }

    func testPowerAndThermalRestrictionsSuspendDecorativeWork() {
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            let restricted = VisualWorkBudget(lowPower: true, thermalState: state)
            XCTAssertFalse(restricted.allowsDecorativeMotion)
            XCTAssertEqual(restricted.visualizerInterval, 1.0 / 20)
            let normal = VisualWorkBudget(lowPower: false, thermalState: state)
            XCTAssertEqual(normal.allowsDecorativeMotion, state == .nominal || state == .fair)
        }
    }
}
