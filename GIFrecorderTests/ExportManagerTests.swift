import XCTest
@testable import GIFrecorder

final class ExportManagerTests: XCTestCase {

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

    func testExportFormatFileExtensions() {
        XCTAssertEqual(ExportFormat.mp4.fileExtension, "mp4")
        XCTAssertEqual(ExportFormat.mov.fileExtension, "mov")
        XCTAssertEqual(ExportFormat.gif.fileExtension, "gif")
    }

    func testExportFormatDisplayNames() {
        XCTAssertEqual(ExportFormat.mp4.displayName, "MP4")
        XCTAssertEqual(ExportFormat.mov.displayName, "MOV")
        XCTAssertEqual(ExportFormat.gif.displayName, "GIF")
    }

    func testExportFormatAudioSupport() {
        XCTAssertTrue(ExportFormat.mp4.supportsAudio)
        XCTAssertTrue(ExportFormat.mov.supportsAudio)
        XCTAssertFalse(ExportFormat.gif.supportsAudio)
    }

    func testExportFormatAllCases() {
        XCTAssertEqual(ExportFormat.allCases.count, 3)
    }
}
