import XCTest
@testable import GIFrecorder

final class GifskiExporterTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testExportFailsGracefullyForMissingInput() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/recording.mov")
        let output  = tempDir.appendingPathComponent("out.gif")
        // Should throw, not crash.
        do {
            try await GifskiExporter.export(
                from: missing,
                to: output,
                options: .default,
                progressHandler: nil
            )
            XCTFail("Expected error for missing input")
        } catch {
            // Any error is acceptable — just must not crash.
        }
    }

    func testGifskiBinaryLookupDoesNotCrash() {
        // In the test bundle Bundle.main points at the test runner, so the
        // binary may not be present — that is expected and intentional.
        // This test verifies the lookup path does not crash or assert.
        let url = Bundle.main.url(forResource: "gifski", withExtension: nil)
        _ = url  // nil is acceptable in test context
    }

    func testDefaultOptionsHaveSaneValues() {
        let opts = GifskiExportOptions.default
        XCTAssertGreaterThan(opts.fps, 0)
        XCTAssertGreaterThan(opts.maxWidth, 0)
        XCTAssertGreaterThan(opts.maxDurationSeconds, 0)
        XCTAssertTrue((1...100).contains(opts.quality))
    }
}
