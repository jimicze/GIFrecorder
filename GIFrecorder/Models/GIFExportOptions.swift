import Foundation

/// Parameters controlling the quality and size of a GIF export.
struct GIFExportOptions {
    /// Output frame rate (frames per second). Higher = smoother but larger file.
    var fps: Int

    /// Maximum output width in pixels. Aspect ratio is preserved.
    var maxWidth: Int

    /// Maximum duration to encode in seconds. Longer clips are truncated.
    var maxDurationSeconds: Int

    static let `default` = GIFExportOptions(fps: 15, maxWidth: 1280, maxDurationSeconds: 30)
}
