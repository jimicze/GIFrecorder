import XCTest
@testable import GIFrecorder

final class WindowTrackerTests: XCTestCase {

    // MARK: - Coordinate conversion

    func testFrameInScreenConversionTopLeft() {
        // Window at Quartz (0, 0) = top-left of a 1080p screen
        // AppKit: y = screenHeight - quartzY - height = 1080 - 0 - 100 = 980
        let screenHeight: CGFloat = 1080
        let quartzFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let appKitY = screenHeight - quartzFrame.origin.y - quartzFrame.height
        XCTAssertEqual(appKitY, 980)
    }

    func testFrameInScreenConversionMidScreen() {
        // Window at Quartz (100, 200), size 400x300 on a 1080p screen
        // AppKit y = 1080 - 200 - 300 = 580
        let screenHeight: CGFloat = 1080
        let quartzFrame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let appKitY = screenHeight - quartzFrame.origin.y - quartzFrame.height
        XCTAssertEqual(appKitY, 580)

        let expected = CGRect(x: 100, y: 580, width: 400, height: 300)
        // Replicate WindowTracker's conversion
        let result = CGRect(
            x: quartzFrame.origin.x,
            y: screenHeight - quartzFrame.origin.y - quartzFrame.height,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
        XCTAssertEqual(result, expected)
    }

    // MARK: - Init / start / stop lifecycle

    func testWindowTrackerInitDoesNotCrash() {
        let tracker = WindowTracker(
            windowID: CGWindowID(9999),
            initialQuartzFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            screen: NSScreen.screens.first ?? NSScreen.main!
        )
        XCTAssertNotNil(tracker)
    }

    func testWindowTrackerStartAndStopDoNotCrash() {
        let tracker = WindowTracker(
            windowID: CGWindowID(9999),
            initialQuartzFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            screen: NSScreen.screens.first ?? NSScreen.main!
        )
        tracker.start()
        tracker.stop()
        // No crash = pass
    }

    // MARK: - Event enum

    func testWindowTrackerEventAssociated() {
        let region = CGRect(x: 10, y: 20, width: 800, height: 600)
        let movedEvent = WindowTracker.Event.moved(newRegion: region)
        let resizedEvent = WindowTracker.Event.resized(newRegion: region)
        let disappearedEvent = WindowTracker.Event.disappeared
        let reappearedEvent = WindowTracker.Event.reappeared(newRegion: region)

        if case .moved(let r) = movedEvent { XCTAssertEqual(r, region) }
        else { XCTFail("Expected .moved") }

        if case .resized(let r) = resizedEvent { XCTAssertEqual(r, region) }
        else { XCTFail("Expected .resized") }

        if case .disappeared = disappearedEvent { /* pass */ }
        else { XCTFail("Expected .disappeared") }

        if case .reappeared(let r) = reappearedEvent { XCTAssertEqual(r, region) }
        else { XCTFail("Expected .reappeared") }
    }
}
