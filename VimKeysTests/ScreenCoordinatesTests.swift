import CoreGraphics
import XCTest
@testable import VimKeys

final class ScreenCoordinatesTests: XCTestCase {
    func testFlipIsItsOwnInverse() {
        let rect = CGRect(x: 100, y: 50, width: 40, height: 20)
        let height: CGFloat = 1080
        let once = ScreenCoordinates.flip(rect, primaryHeight: height)
        XCTAssertEqual(ScreenCoordinates.flip(once, primaryHeight: height), rect)
    }

    func testFlipPrimaryTopLeft() {
        // A rect at the AX top-left (y=0) maps to Cocoa y = H - height.
        let height: CGFloat = 1000
        let ax = CGRect(x: 0, y: 0, width: 100, height: 30)
        XCTAssertEqual(
            ScreenCoordinates.flip(ax, primaryHeight: height),
            CGRect(x: 0, y: 970, width: 100, height: 30)
        )
    }

    func testFlipDisplayAbovePrimaryHasNegativeAXY() {
        // A display stacked above the primary occupies Cocoa Y >= H; its AX
        // Y is negative. Round-trips exactly.
        let height: CGFloat = 1080
        let cocoaAbovePrimary = CGRect(x: 0, y: 1080, width: 200, height: 100)
        let ax = ScreenCoordinates.flip(cocoaAbovePrimary, primaryHeight: height)
        XCTAssertEqual(ax.minY, -100) // H - maxY = 1080 - 1180
        XCTAssertEqual(ScreenCoordinates.flip(ax, primaryHeight: height), cocoaAbovePrimary)
    }

    func testPointInPanelIsIdentityOnPrimary() {
        // Panel covering the primary display (Cocoa origin 0,0) leaves AX
        // points unchanged — matches the pre-fix single-monitor behavior.
        let height: CGFloat = 900
        let panel = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let badge = CGPoint(x: 300, y: 120)
        XCTAssertEqual(
            ScreenCoordinates.pointInPanel(axPoint: badge, panelCocoaFrame: panel, primaryHeight: height),
            badge
        )
    }

    func testPointInPanelOnSecondaryToTheRight() {
        // Secondary display to the right at Cocoa (1440,0); a badge at AX
        // (1440+50, 30) sits 50pt from the panel's left edge.
        let height: CGFloat = 900
        let panel = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let badge = CGPoint(x: 1490, y: 30)
        XCTAssertEqual(
            ScreenCoordinates.pointInPanel(axPoint: badge, panelCocoaFrame: panel, primaryHeight: height),
            CGPoint(x: 50, y: 30)
        )
    }

    func testPointInPanelOnSecondaryAbove() {
        // Secondary display stacked above the primary at Cocoa (0,900);
        // its AX origin is (0, -900). A badge near that screen's top-left at
        // AX (10, -880) lands 10pt right / 20pt down inside the panel.
        let height: CGFloat = 900
        let panel = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let badge = CGPoint(x: 10, y: -880)
        XCTAssertEqual(
            ScreenCoordinates.pointInPanel(axPoint: badge, panelCocoaFrame: panel, primaryHeight: height),
            CGPoint(x: 10, y: 20)
        )
    }
}
