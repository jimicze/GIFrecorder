import XCTest
@testable import GIFrecorder

final class RecordingSessionTests: XCTestCase {

    func testSessionCreation() {
        let region = CGRect(x: 0, y: 0, width: 800, height: 600)
        let config = RecordingConfig(fps: 30, capturesAudio: true, exportFormat: .mp4)
        let session = RecordingSession(region: region, config: config)

        XCTAssertNotNil(session.id)
        XCTAssertEqual(session.region, region)
        XCTAssertEqual(session.config.fps, 30)
        XCTAssertNil(session.endDate)
        XCTAssertNil(session.temporaryFileURL)
    }

    func testSessionDuration() {
        let region = CGRect(x: 0, y: 0, width: 640, height: 480)
        let config = RecordingConfig.default
        var session = RecordingSession(region: region, config: config)

        // Duration before end date set — should be positive (time elapsed since start)
        XCTAssertGreaterThanOrEqual(session.duration, 0)

        // Set end date
        session.endDate = session.startDate.addingTimeInterval(5.0)
        XCTAssertEqual(session.duration, 5.0, accuracy: 0.001)
    }

    func testDefaultRecordingConfig() {
        let config = RecordingConfig.default
        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.capturesAudio, true)
        XCTAssertEqual(config.exportFormat, .mp4)
    }

    func testSessionTrackedWindowIDDefaultsToNil() {
        let region = CGRect(x: 0, y: 0, width: 800, height: 600)
        let config = RecordingConfig.default
        let session = RecordingSession(region: region, config: config)
        XCTAssertNil(session.trackedWindowID)
        XCTAssertNil(session.initialQuartzFrame)
    }

    func testSessionCanSetTrackedWindowID() {
        let region = CGRect(x: 0, y: 0, width: 800, height: 600)
        let config = RecordingConfig.default
        var session = RecordingSession(region: region, config: config)
        session.trackedWindowID = CGWindowID(42)
        session.initialQuartzFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertEqual(session.trackedWindowID, CGWindowID(42))
        XCTAssertEqual(session.initialQuartzFrame, CGRect(x: 100, y: 200, width: 800, height: 600))
    }
}
