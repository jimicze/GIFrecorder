import AVFoundation
import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.lasakondrej.gifrecorder", category: "GifskiExporter")

/// Options for gifski GIF encoding. Mirrors GIFExportOptions for drop-in compatibility.
struct GifskiExportOptions {
    var fps: Int = 15
    var maxWidth: Int = 1280
    var maxDurationSeconds: Int = 30
    var quality: Int = 80        // 1–100; 80 is visually excellent at reasonable file sizes

    static let `default` = GifskiExportOptions()
}

/// Exports a video file to an animated GIF using the bundled gifski binary.
/// Falls back gracefully by throwing on any failure — caller should catch and use GIFExporter.
enum GifskiExporter {

    enum GifskiError: LocalizedError {
        case gifskiBinaryNotFound
        case frameExtractionFailed(underlying: Error)
        case gifskiProcessFailed(exitCode: Int32, stderr: String)
        case noFramesExtracted

        var errorDescription: String? {
            switch self {
            case .gifskiBinaryNotFound:
                return "gifski binary not found in app bundle."
            case .frameExtractionFailed(let e):
                return "Frame extraction failed: \(e.localizedDescription)"
            case .gifskiProcessFailed(let code, let stderr):
                return "gifski exited \(code): \(stderr)"
            case .noFramesExtracted:
                return "No frames were extracted from the recording."
            }
        }
    }

    // MARK: - Public API

    static func export(
        from sourceURL: URL,
        to destinationURL: URL,
        options: GifskiExportOptions = .default,
        timeRange: CMTimeRange? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        // Locate bundled binary (flat copy in Contents/Resources/).
        guard let binaryURL = Bundle.main.url(forResource: "gifski", withExtension: nil) else {
            throw GifskiError.gifskiBinaryNotFound
        }

        // Create temp dir for PNG frames.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifski-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Extract PNG frames.
        let framePaths = try await extractFrames(
            from: sourceURL,
            to: tempDir,
            options: options,
            timeRange: timeRange,
            progressHandler: progressHandler
        )

        guard !framePaths.isEmpty else { throw GifskiError.noFramesExtracted }

        // Ensure output does not exist (AVAssetWriter / gifski refuse to overwrite).
        try? FileManager.default.removeItem(at: destinationURL)

        // Run gifski process.
        try await runGifski(
            binary: binaryURL,
            frames: framePaths,
            fps: options.fps,
            width: options.maxWidth,
            quality: options.quality,
            output: destinationURL
        )

        logger.info("GifskiExporter: done → \(destinationURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Frame extraction

    private static func extractFrames(
        from sourceURL: URL,
        to tempDir: URL,
        options: GifskiExportOptions,
        timeRange: CMTimeRange?,
        progressHandler: ((Double) -> Void)?
    ) async throws -> [URL] {
        let asset = AVURLAsset(url: sourceURL)
        guard let assetDuration = try? await asset.load(.duration) else {
            throw GifskiError.frameExtractionFailed(
                underlying: NSError(domain: "GifskiExporter", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Could not read asset duration"])
            )
        }

        // Respect trim range if provided.
        let startSeconds = timeRange.map { CMTimeGetSeconds($0.start) } ?? 0
        let rawDuration: Double
        if let tr = timeRange {
            rawDuration = CMTimeGetSeconds(tr.duration)
        } else {
            rawDuration = CMTimeGetSeconds(assetDuration)
        }
        let totalSeconds = min(rawDuration, Double(options.maxDurationSeconds))
        guard totalSeconds > 0 else {
            throw GifskiError.frameExtractionFailed(
                underlying: NSError(domain: "GifskiExporter", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Zero duration"])
            )
        }

        let gifFPS = Double(options.fps)
        let frameCount = max(1, Int(totalSeconds * gifFPS))
        let frameDuration: TimeInterval = 1.0 / gifFPS

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maxWidth * 2, height: options.maxWidth * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: frameDuration / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: frameDuration / 2, preferredTimescale: 600)

        var framePaths: [URL] = []

        for i in 0..<frameCount {
            let t = CMTime(seconds: startSeconds + Double(i) * frameDuration, preferredTimescale: 600)
            do {
                var actual = CMTime.zero
                let cgImage = try generator.copyCGImage(at: t, actualTime: &actual)
                let frameURL = tempDir.appendingPathComponent(
                    String(format: "frame-%05d.png", i)
                )
                guard let dest = CGImageDestinationCreateWithURL(
                    frameURL as CFURL, "public.png" as CFString, 1, nil
                ) else { continue }
                CGImageDestinationAddImage(dest, cgImage, nil)
                CGImageDestinationFinalize(dest)
                framePaths.append(frameURL)
            } catch {
                logger.warning("GifskiExporter: skipped frame \(i): \(error.localizedDescription, privacy: .public)")
            }

            await Task.yield()
            // First 50 % of reported progress = frame extraction.
            progressHandler?(Double(i + 1) / Double(frameCount) * 0.5)
        }

        return framePaths.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - gifski process

    private static func runGifski(
        binary: URL,
        frames: [URL],
        fps: Int,
        width: Int,
        quality: Int,
        output: URL
    ) async throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--fps", "\(fps)",
            "--width", "\(width)",
            "--quality", "\(quality)",
            "--output", output.path,
        ] + frames.map(\.path)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        // Wait on a background thread to avoid blocking Swift concurrency pool.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                let code = process.terminationStatus
                if code == 0 {
                    continuation.resume()
                } else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: GifskiError.gifskiProcessFailed(exitCode: code, stderr: stderr)
                    )
                }
            }
        }
    }
}
