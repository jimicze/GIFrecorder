import XCTest
@testable import GIFrecorder

final class ThumbnailGeneratorTests: XCTestCase {

    func testVideoThumbnailReturnsNilForMissingFile() async {
        let url = URL(fileURLWithPath: "/nonexistent/file.mp4")
        let result = await ThumbnailGenerator.generate(from: url, format: .mp4)
        XCTAssertNil(result)
    }

    func testGIFThumbnailReturnsNilForMissingFile() async {
        let url = URL(fileURLWithPath: "/nonexistent/file.gif")
        let result = await ThumbnailGenerator.generate(from: url, format: .gif)
        XCTAssertNil(result)
    }
}
