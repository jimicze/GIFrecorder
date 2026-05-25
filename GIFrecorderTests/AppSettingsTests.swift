import XCTest
@testable import GIFrecorder

final class AppSettingsTests: XCTestCase {

    func testDefaultValues() {
        // Settings should have sensible defaults
        let settings = AppSettings.shared
        XCTAssertTrue([15, 30, 60].contains(settings.fps))
        XCTAssertNotNil(settings.defaultFormat)
    }

    func testFPSOptions() {
        let validFPS = [15, 30, 60]
        for fps in validFPS {
            AppSettings.shared.fps = fps
            XCTAssertEqual(AppSettings.shared.fps, fps)
        }
    }

    func testDefaultFormat() {
        for format in ExportFormat.allCases {
            AppSettings.shared.defaultFormat = format
            XCTAssertEqual(AppSettings.shared.defaultFormat, format)
        }
    }

    func testRecordingConfig() {
        AppSettings.shared.fps = 30
        AppSettings.shared.capturesAudio = true
        AppSettings.shared.defaultFormat = .mp4

        let config = AppSettings.shared.recordingConfig
        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.capturesAudio, true)
        XCTAssertEqual(config.exportFormat, .mp4)
    }
}
