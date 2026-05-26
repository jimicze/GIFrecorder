import XCTest
import AVFoundation
import CoreGraphics
@testable import GIFrecorder

final class SegmentStitcherTests: XCTestCase {

    // MARK: - Scale-to-fit transform math

    func testScaleToFitTransformSameSize() {
        let t = SegmentStitcher.scaleToFit(sourceSize: CGSize(width: 800, height: 600),
                                            canvasSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(t.a, 1, accuracy: 0.001)
        XCTAssertEqual(t.d, 1, accuracy: 0.001)
        XCTAssertEqual(t.tx, 0, accuracy: 0.001)
        XCTAssertEqual(t.ty, 0, accuracy: 0.001)
    }

    func testScaleToFitTransformScaleDown() {
        let t = SegmentStitcher.scaleToFit(sourceSize: CGSize(width: 800, height: 600),
                                            canvasSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(t.a, 0.5, accuracy: 0.001)
        XCTAssertEqual(t.d, 0.5, accuracy: 0.001)
        XCTAssertEqual(t.tx, 0, accuracy: 0.001)
        XCTAssertEqual(t.ty, 0, accuracy: 0.001)
    }

    func testScaleToFitTransformLetterbox() {
        let t = SegmentStitcher.scaleToFit(sourceSize: CGSize(width: 1920, height: 400),
                                            canvasSize: CGSize(width: 800, height: 600))
        let expectedScale = 800.0 / 1920.0
        let fittedH = 400.0 * expectedScale
        let expectedTY = (600.0 - fittedH) / 2.0
        XCTAssertEqual(t.a, expectedScale, accuracy: 0.001)
        XCTAssertEqual(t.d, expectedScale, accuracy: 0.001)
        XCTAssertEqual(t.tx, 0, accuracy: 0.001)
        XCTAssertEqual(t.ty, expectedTY, accuracy: 0.5)
    }

    func testScaleToFitTransformPillarbox() {
        let t = SegmentStitcher.scaleToFit(sourceSize: CGSize(width: 400, height: 1200),
                                            canvasSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(t.a, 0.5, accuracy: 0.001)
        XCTAssertEqual(t.d, 0.5, accuracy: 0.001)
        XCTAssertEqual(t.tx, 300, accuracy: 0.5)
        XCTAssertEqual(t.ty, 0, accuracy: 0.001)
    }

    func testStitchRequiresMoreThanOneSegment() async {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-stitch-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            try await SegmentStitcher.stitch([], outputURL: outputURL)
            XCTFail("Expected stitch to throw for 0 segments")
        } catch {
            // Any error is acceptable
        }
    }
}
