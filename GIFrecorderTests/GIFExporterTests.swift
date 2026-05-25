import XCTest
@testable import GIFrecorder

final class GIFExporterTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    func testGIFExporterDefaultOptionsMaxDuration() {
        // Ensure default options max duration is reasonable
        XCTAssertEqual(GIFExportOptions.default.maxDurationSeconds, 30)
    }

    func testGIFExporterDefaultOptionsMaxWidth() {
        // Ensure default options max width is set
        XCTAssertEqual(GIFExportOptions.default.maxWidth, 1280)
    }

    func testGIFExporterDefaultOptionsFPS() {
        // Ensure default options fps is set
        XCTAssertEqual(GIFExportOptions.default.fps, 15)
    }
}
