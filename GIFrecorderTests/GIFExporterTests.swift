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

    func testGIFExporterMaxDuration() {
        // Ensure max duration constant is reasonable
        XCTAssertEqual(GIFExporter.maxDuration, 30)
    }

    func testGIFExporterMaxWidth() {
        // Ensure max width constant is set
        XCTAssertEqual(GIFExporter.maxWidth, 1280)
    }
}
