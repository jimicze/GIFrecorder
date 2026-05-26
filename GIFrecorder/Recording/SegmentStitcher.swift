@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import os

private let logger = Logger(subsystem: "com.lasakondrej.gifrecorder", category: "SegmentStitcher")

/// Stitches multiple .mov segments into a single .mov file.
/// Gaps between segments are filled with a freeze-frame from the preceding segment.
/// Output canvas size = first segment's dimensions.
/// Subsequent segments with different dimensions are scaled to fit (letterbox/pillarbox).
enum SegmentStitcher {

    /// Stitches `segments` (≥2 .mov files) into a single .mov at `outputURL`.
    /// On success, all input segment files are deleted.
    /// Throws `ExportError.exportFailed` on failure.
    static func stitch(_ segments: [URL], outputURL: URL) async throws {
        guard segments.count >= 2 else {
            throw ExportError.exportFailed("stitch() requires ≥2 segments; got \(segments.count)")
        }

        struct SegInfo {
            let asset: AVAsset
            let videoTrack: AVAssetTrack
            let size: CGSize
            let duration: CMTime
        }

        var infos: [SegInfo] = []
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.exportFailed("Segment \(url.lastPathComponent) has no video track")
            }
            let size = try await vt.load(.naturalSize)
            let duration = try await asset.load(.duration)
            infos.append(SegInfo(asset: asset, videoTrack: vt, size: size, duration: duration))
        }

        let canvasSize = infos[0].size
        // Derive frame duration from the first segment's video track.
        // Falls back to 30fps if the track has no min frame duration.
        let rawFrameDuration = (try? await infos[0].videoTrack.load(.minFrameDuration)) ?? CMTime(value: 1, timescale: 30)
        let frameDuration = rawFrameDuration.isValid && rawFrameDuration > .zero
            ? rawFrameDuration
            : CMTime(value: 1, timescale: 30)

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.exportFailed("Could not add video track to composition")
        }
        let compAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var videoInstructions: [AVMutableVideoCompositionInstruction] = []
        var currentTime = CMTime.zero
        var fillerURLs: [URL] = []

        for (index, info) in infos.enumerated() {
            let segStart = currentTime
            let segTimeRange = CMTimeRange(start: .zero, duration: info.duration)

            // Insert video
            try compVideoTrack.insertTimeRange(segTimeRange, of: info.videoTrack, at: segStart)

            // Insert audio if present
            if let audioTrack = try? await info.asset.loadTracks(withMediaType: .audio).first,
               let compAudio = compAudioTrack {
                try? compAudio.insertTimeRange(segTimeRange, of: audioTrack, at: segStart)
            }

            // Build per-segment video composition instruction
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(
                assetTrack: compVideoTrack
            )
            let transform = scaleToFit(sourceSize: info.size, canvasSize: canvasSize)
            layerInstruction.setTransform(transform, at: segStart)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: segStart, duration: info.duration)
            instruction.layerInstructions = [layerInstruction]
            videoInstructions.append(instruction)

            currentTime = CMTimeAdd(segStart, info.duration)

            // Insert freeze-frame filler between segments
            if index < infos.count - 1 {
                let fillerStart = currentTime
                let fillerDuration = frameDuration

                let fillerURL: URL
                do {
                    fillerURL = try await makeFreezeFiller(
                        from: info.asset,
                        size: info.size
                    )
                } catch {
                    flog("SegmentStitcher — filler creation failed: \(error.localizedDescription); skipping filler")
                    continue
                }
                fillerURLs.append(fillerURL)

                let fillerAsset = AVURLAsset(url: fillerURL)
                if let fillerVT = try? await fillerAsset.loadTracks(withMediaType: .video).first {
                    let fillerTimeRange = CMTimeRange(start: .zero, duration: fillerDuration)
                    try? compVideoTrack.insertTimeRange(fillerTimeRange, of: fillerVT, at: fillerStart)

                    let fillerLayerInstruction = AVMutableVideoCompositionLayerInstruction(
                        assetTrack: compVideoTrack
                    )
                    fillerLayerInstruction.setTransform(
                        scaleToFit(sourceSize: info.size, canvasSize: canvasSize),
                        at: fillerStart
                    )
                    let fillerInstruction = AVMutableVideoCompositionInstruction()
                    fillerInstruction.timeRange = CMTimeRange(start: fillerStart, duration: fillerDuration)
                    fillerInstruction.layerInstructions = [fillerLayerInstruction]
                    videoInstructions.append(fillerInstruction)

                    currentTime = CMTimeAdd(fillerStart, fillerDuration)
                }
            }
        }

        // Build video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvasSize
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = videoInstructions

        // Export
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportFailed("Could not create AVAssetExportSession for stitch")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition

        await exportSession.export()

        // Clean up filler temp files
        for url in fillerURLs { try? FileManager.default.removeItem(at: url) }

        if let error = exportSession.error {
            throw ExportError.exportFailed("Stitch export failed: \(error.localizedDescription)")
        }

        // Clean up input segment files
        for url in segments { try? FileManager.default.removeItem(at: url) }

        flog("SegmentStitcher — stitched \(segments.count) segments → \(outputURL.lastPathComponent)")
    }

    // MARK: - Internal helpers (internal for testability)

    /// Computes a scale+translate CGAffineTransform that fits `sourceSize` into `canvasSize`
    /// while preserving aspect ratio (letterbox/pillarbox). Result is centred on the canvas.
    static func scaleToFit(sourceSize: CGSize, canvasSize: CGSize) -> CGAffineTransform {
        let scale = min(canvasSize.width / sourceSize.width,
                        canvasSize.height / sourceSize.height)
        let tx = (canvasSize.width  - sourceSize.width  * scale) / 2.0
        let ty = (canvasSize.height - sourceSize.height * scale) / 2.0
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }

    // MARK: - Freeze-frame filler

    /// Creates a short single-frame .mov clip containing the last frame of `asset`.
    private static func makeFreezeFiller(
        from asset: AVAsset,
        size: CGSize
    ) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true

        let assetDuration = try await asset.load(.duration)
        let lastFrameTime = CMTimeSubtract(assetDuration, CMTime(value: 1, timescale: 30))
        let safeTime = CMTimeMaximum(lastFrameTime, .zero)

        let cgImage = try await generator.image(at: safeTime).image

        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        guard let pb = pixelBuffer else {
            throw ExportError.exportFailed("Could not create pixel buffer for freeze filler")
        }
        let ciImage = CIImage(cgImage: cgImage)
        let ciContext = CIContext()
        ciContext.render(ciImage, to: pb)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifrecorder-filler-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: tempURL)

        let writer = try AVAssetWriter(url: tempURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "filler startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        var attempts = 0
        while !input.isReadyForMoreMediaData && attempts < 50 {
            try await Task.sleep(nanoseconds: 10_000_000)
            attempts += 1
        }
        guard input.isReadyForMoreMediaData else {
            writer.cancelWriting()
            throw ExportError.exportFailed("Filler writer input not ready after 500ms")
        }

        adaptor.append(pb, withPresentationTime: .zero)
        input.markAsFinished()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: ExportError.writerFailed(
                            writer.error?.localizedDescription ?? "filler finishWriting failed"
                        )
                    )
                }
            }
        }

        return tempURL
    }
}
