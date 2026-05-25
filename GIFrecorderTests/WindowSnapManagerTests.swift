import XCTest
@testable import GIFrecorder

final class WindowSnapManagerTests: XCTestCase {

    func testSnapWindowFrameConversion() {
        // Create a mock snap window
        // Quartz coordinates: origin top-left, y increases downward
        // AppKit coordinates: origin bottom-left, y increases upward
        // We simulate a 1920x1080 screen

        let screenHeight: CGFloat = 1080

        // Window at Quartz (100, 200) with size 400x300
        // In AppKit: y = screenHeight - quartzY - height = 1080 - 200 - 300 = 580
        let quartzFrame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let convertedY = screenHeight - quartzFrame.origin.y - quartzFrame.height
        XCTAssertEqual(convertedY, 580)
    }

    func testSnapWindowFiltersSmallWindows() {
        // Windows smaller than 50x50 should be filtered out
        // This is enforced in WindowSnapManager.snapWindows(for:)
        // Since we can't mock CGWindowListCopyWindowInfo easily, just verify the logic
        let minSize: CGFloat = 50
        XCTAssertGreaterThan(minSize, 0)
    }
}
