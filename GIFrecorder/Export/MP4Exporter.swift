import AVFoundation

/// Exports a .mov file to H.264 MP4 using AVAssetExportSession.
enum MP4Exporter {

    static func export(from sourceURL: URL, to destinationURL: URL, timeRange: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: sourceURL)

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportFailed("Could not create AVAssetExportSession")
        }

        session.outputURL = destinationURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let range = timeRange {
            session.timeRange = range
        }

        await session.export()

        if let error = session.error {
            throw ExportError.exportFailed(error.localizedDescription)
        }

        guard session.status == .completed else {
            throw ExportError.exportFailed("Export session did not complete (status: \(session.status.rawValue))")
        }
    }
}
