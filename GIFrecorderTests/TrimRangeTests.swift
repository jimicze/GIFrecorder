import XCTest
import CoreMedia
@testable import GIFrecorder

final class TrimRangeTests: XCTestCase {

    func testTimeRange() {
        let start = CMTime(seconds: 2, preferredTimescale: 600)
        let end   = CMTime(seconds: 8, preferredTimescale: 600)
        let trim  = TrimRange(start: start, end: end)
        let range = trim.cmTimeRange
        XCTAssertEqual(CMTimeGetSeconds(range.start), 2, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(range.duration), 6, accuracy: 0.001)
    }

    func testFromFractions() {
        let duration = CMTime(seconds: 10, preferredTimescale: 600)
        let trim = TrimRange.fromFractions(startFraction: 0.2, endFraction: 0.8, duration: duration)
        XCTAssertEqual(CMTimeGetSeconds(trim.start), 2, accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(trim.end), 8, accuracy: 0.01)
    }
}
