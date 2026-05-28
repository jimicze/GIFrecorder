import XCTest
@testable import GIFrecorder

final class RecordingEngineTests: XCTestCase {

    // MARK: - RecordingError descriptions

    func testPermissionDeniedErrorDescription() {
        let error = RecordingError.permissionDenied
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("permission"), "Should mention permission")
    }

    func testNoDisplayFoundErrorDescription() {
        let error = RecordingError.noDisplayFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("display"), "Should mention display")
    }

    func testStreamSetupFailedErrorDescription() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "test error"])
        let error = RecordingError.streamSetupFailed(underlying: underlying)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("test error"), "Should embed underlying error message")
    }

    func testAlreadyRecordingErrorDescription() {
        let error = RecordingError.alreadyRecording
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func testNotRecordingErrorDescription() {
        let error = RecordingError.notRecording
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    // MARK: - RecordingConfig defaults

    func testRecordingConfigDefaultFPS() {
        XCTAssertEqual(RecordingConfig.default.fps, 30)
    }

    func testRecordingConfigDefaultFormat() {
        XCTAssertEqual(RecordingConfig.default.exportFormat, .mp4)
    }

    func testRecordingConfigDefaultCapturesAudio() {
        XCTAssertTrue(RecordingConfig.default.capturesAudio)
    }

    func testRecordingConfigCustomInit() {
        let config = RecordingConfig(fps: 60, capturesAudio: false, exportFormat: .gif)
        XCTAssertEqual(config.fps, 60)
        XCTAssertFalse(config.capturesAudio)
        XCTAssertEqual(config.exportFormat, .gif)
    }

    // MARK: - New tracking methods exist

    func testPauseCaptureExistsAndDoesNotCrashWhenNotRecording() async {
        await RecordingEngine.shared.pauseCapture()
        // No crash = pass
    }

    func testResumeCaptureExistsAndDoesNotCrashWhenNotRecording() async {
        let region = CGRect(x: 0, y: 0, width: 800, height: 600)
        await RecordingEngine.shared.resumeCapture(newRegion: region)
        // No crash = pass
    }

    func testRestartCaptureThrowsWhenNotRecording() async {
        let region = CGRect(x: 0, y: 0, width: 800, height: 600)
        do {
            try await RecordingEngine.shared.restartCapture(newRegion: region)
            XCTFail("Expected restartCapture to throw when not recording")
        } catch let error as RecordingError {
            if case .notRecording = error { /* expected */ }
            else { XCTFail("Expected RecordingError.notRecording, got \(error)") }
        } catch {
            XCTFail("Expected RecordingError, got \(error)")
        }
    }

    // MARK: - Stop without start

    func testStopWithoutStartThrows() async {
        // RecordingEngine.shared is not recording — stop() must throw .notRecording.
        do {
            _ = try await RecordingEngine.shared.stop()
            XCTFail("Expected stop() to throw when not recording")
        } catch let error as RecordingError {
            if case .notRecording = error {
                // expected
            } else {
                XCTFail("Expected RecordingError.notRecording, got \(error)")
            }
        } catch {
            XCTFail("Expected RecordingError, got \(error)")
        }
    }
}
