@preconcurrency import AVFoundation
import CoreVideo
import CoreImage
@preconcurrency import ImageIO
import UniformTypeIdentifiers

/// Exports a .mov recording to an animated GIF using ImageIO + AVAssetImageGenerator.
///
/// Frames are generated serially (one at a time) which:
///   - eliminates the data-race present in async concurrent generation
///   - keeps memory pressure low (no concurrent frame buffers)
///   - lets the progress callback be called on the calling actor without synchronisation
enum GIFExporter {

    static func export(
        from sourceURL: URL,
        to destinationURL: URL,
        options: GIFExportOptions = .default,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)

        // Clamp duration to options.maxDurationSeconds
        let duration = try await asset.load(.duration)
        let durationSeconds = min(CMTimeGetSeconds(duration), Double(options.maxDurationSeconds))

        // Determine output dimensions
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ExportError.readerFailed("No video track found")
        }
        let naturalSize = try await track.load(.naturalSize)
        let scale = min(1.0, CGFloat(options.maxWidth) / max(naturalSize.width, 1))
        let outputSize = CGSize(
            width: (naturalSize.width * scale).rounded(),
            height: (naturalSize.height * scale).rounded()
        )

        // Build frame timestamps at options.fps
        let gifFPS: Double = Double(options.fps)
        let frameCount = max(1, Int(durationSeconds * gifFPS))
        let frameDuration: TimeInterval = 1.0 / gifFPS
        let times: [CMTime] = (0..<frameCount).map {
            CMTime(seconds: Double($0) * frameDuration, preferredTimescale: 600)
        }

        // Configure image generator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = outputSize
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: 30)

        // Remove existing output file — CGImageDestinationCreateWithURL fails on existing files
        try? FileManager.default.removeItem(at: destinationURL)

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw ExportError.exportFailed("Could not create GIF destination at \(destinationURL.path)")
        }

        // GIF-level properties: infinite loop
        let gifFileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
            ],
        ]
        CGImageDestinationSetProperties(destination, gifFileProperties as CFDictionary)

        // Per-frame properties
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration,
            ],
        ]

        // Generate and write frames serially — no concurrency, no data race.
        // copyCGImage(at:actualTime:) blocks the cooperative thread briefly per frame,
        // which is acceptable inside an async context for this use case.
        for (index, time) in times.enumerated() {
            // Yield so the cooperative thread pool stays responsive.
            await Task.yield()

            do {
                var actualTime = CMTime.zero
                let cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)
                CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            } catch {
                // Skip frames that cannot be decoded (e.g. beyond actual duration)
            }

            progressHandler?(Double(index + 1) / Double(frameCount))
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.exportFailed("Failed to finalise GIF at \(destinationURL.path)")
        }
    }
}
