import AVFoundation
import os

private let logger = Logger(subsystem: "com.gifrecorder.app", category: "ExportManager")

/// Typed errors for the export pipeline.
enum ExportError: LocalizedError {
    case writerFailed(String)
    case readerFailed(String)
    case exportFailed(String)
    case gifskiFailed(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .writerFailed(let msg): return "Writer failed: \(msg)"
        case .readerFailed(let msg): return "Reader failed: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        case .gifskiFailed(let msg): return "GIF export failed: \(msg)"
        case .unsupportedFormat: return "Unsupported export format."
        }
    }
}

/// Dispatches export to format-specific exporters.
final class ExportManager {

    static let shared = ExportManager()
    private init() {}

    /// Export a recorded .mov file to the given format and destination URL.
    /// - Parameters:
    ///   - sourceURL: Temporary .mov file from RecordingEngine
    ///   - format: Target format (mp4, mov, gif)
    ///   - destinationURL: Final output path (chosen by user via save dialog)
    ///   - timeRange: Optional trim range; nil exports the full duration
    ///   - progressHandler: Reports progress 0.0–1.0 (GIF only)
    func export(
        from sourceURL: URL,
        to format: ExportFormat,
        destination destinationURL: URL,
        timeRange: CMTimeRange? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        // Delete existing file at destination
        try? FileManager.default.removeItem(at: destinationURL)

        switch format {
        case .mp4:
            try await MP4Exporter.export(from: sourceURL, to: destinationURL, timeRange: timeRange)
        case .mov:
            try await MOVExporter.export(from: sourceURL, to: destinationURL, timeRange: timeRange)
        case .gif:
            if AppSettings.shared.useGifski {
                do {
                    try await GifskiExporter.export(
                        from: sourceURL,
                        to: destinationURL,
                        options: AppSettings.shared.gifskiExportOptions,
                        timeRange: timeRange,
                        progressHandler: progressHandler
                    )
                    return
                } catch {
                    // Log and fall through to the ImageIO exporter.
                    logger.warning(
                        "GifskiExporter failed, falling back to GIFExporter: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            // Fallback / useGifski == false path.
            try await GIFExporter.export(
                from: sourceURL,
                to: destinationURL,
                options: AppSettings.shared.gifExportOptions,
                timeRange: timeRange,
                progressHandler: progressHandler
            )
        }
    }
}
