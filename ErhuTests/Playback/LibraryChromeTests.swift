import XCTest
@testable import Erhu

final class LibraryChromeTests: XCTestCase {
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
