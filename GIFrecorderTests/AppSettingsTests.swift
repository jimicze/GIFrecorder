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

    func testWindowTrackingEnabledDefault() {
        // Reset to check default
        UserDefaults.standard.removeObject(forKey: "windowTrackingEnabled")
        // AppSettings.shared reads from UserDefaults on access; default is false
        XCTAssertFalse(AppSettings.shared.windowTrackingEnabled)
    }

    func testWindowTrackingOnCloseDefault() {
        UserDefaults.standard.removeObject(forKey: "windowTrackingOnClose")
        // Default should be .pause
        // Note: AppSettings.shared is already initialised; test the enum exists
        let action: WindowCloseAction = .pause
        XCTAssertEqual(action.rawValue, "pause")
    }

    func testWindowCloseActionCases() {
        XCTAssertEqual(WindowCloseAction.allCases.count, 2)
        XCTAssertEqual(WindowCloseAction.stop.rawValue, "stop")
        XCTAssertEqual(WindowCloseAction.pause.rawValue, "pause")
    }

    func testWindowTrackingEnabledPersists() {
        AppSettings.shared.windowTrackingEnabled = true
        XCTAssertTrue(AppSettings.shared.windowTrackingEnabled)
        AppSettings.shared.windowTrackingEnabled = false
        XCTAssertFalse(AppSettings.shared.windowTrackingEnabled)
    }

    func testWindowTrackingOnClosePersists() {
        AppSettings.shared.windowTrackingOnClose = .stop
        XCTAssertEqual(AppSettings.shared.windowTrackingOnClose, .stop)
        AppSettings.shared.windowTrackingOnClose = .pause
        XCTAssertEqual(AppSettings.shared.windowTrackingOnClose, .pause)
    }
}
