import Foundation
import CoreGraphics

/// Metadata about a completed or in-progress recording session.
struct RecordingSession: Identifiable {
    let id: UUID
    let startDate: Date
    var endDate: Date?
    let region: CGRect
    let config: RecordingConfig

    /// Temporary file URL written by the recording engine (.mov).
    var temporaryFileURL: URL?

    /// Non-nil only when window tracking is active for this session.
    var trackedWindowID: CGWindowID? = nil

    /// Raw Quartz-coordinate frame of the tracked window at session start.
    /// Quartz: origin = top-left of primary display, Y grows downward.
    var initialQuartzFrame: CGRect? = nil

    var duration: TimeInterval {
        guard let end = endDate else { return Date().timeIntervalSince(startDate) }
        return end.timeIntervalSince(startDate)
    }

    init(region: CGRect, config: RecordingConfig) {
        self.id = UUID()
        self.startDate = Date()
        self.region = region
        self.config = config
    }
}

/// Configuration used to start a recording session.
struct RecordingConfig {
    var fps: Int
    var capturesAudio: Bool
    var exportFormat: ExportFormat

    static let `default` = RecordingConfig(fps: 30, capturesAudio: true, exportFormat: .mp4)
}
