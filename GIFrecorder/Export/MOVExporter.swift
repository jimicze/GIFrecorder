import Foundation
import AVFoundation

/// Exports a recorded .mov by copying/remuxing to a new .mov destination.
enum MOVExporter {

    static func export(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ExportError.exportFailed("Could not create AVAssetExportSession for MOV")
        }

        session.outputURL = destinationURL
        session.outputFileType = .mov

        await session.export()

        if let error = session.error {
            throw ExportError.exportFailed(error.localizedDescription)
        }

        guard session.status == .completed else {
            throw ExportError.exportFailed("MOV export did not complete (status: \(session.status.rawValue))")
        }
    }
}
