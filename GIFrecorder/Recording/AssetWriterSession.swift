@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox
import os

private let logger = Logger(subsystem: "com.gifrecorder.app", category: "AssetWriterSession")

/// Wraps AVAssetWriter to receive CMSampleBuffers from SCStream.
/// Writes video (H.264) and audio (AAC) to a .mov file.
final class AssetWriterSession {

    // MARK: - Properties

    let outputURL: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor

    private var hasStartedSession = false
    private var lastVideoTime: CMTime = .invalid
    private let lock = NSLock()

    // MARK: - Init

    /// - Parameters:
    ///   - url: Destination `.mov` file URL (must not already exist).
    ///   - config: Recording configuration (fps, audio, etc.).
    ///   - videoWidth: Pixel width of the capture region (must be even, ≥ 16).
    ///   - videoHeight: Pixel height of the capture region (must be even, ≥ 16).
    init(url: URL, config: RecordingConfig, videoWidth: Int, videoHeight: Int) throws {
        self.outputURL = url

        // Remove existing file
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(url: url, fileType: .mov)
        self.writer = writer

        // Video input — H.264
        // Width and height must exactly match the pixel dimensions of the SCStream
        // output buffers; H.264 encoder rejects a dimension mismatch at append time.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                kVTCompressionPropertyKey_RealTime as String: true,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        self.videoInput = videoInput

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        self.pixelBufferAdaptor = adaptor

        // Audio input — AAC (optional)
        var audioInput: AVAssetWriterInput?
        if config.capturesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            audioInput = ai
        }
        self.audioInput = audioInput

        // Add inputs to writer
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        if let ai = audioInput, writer.canAdd(ai) { writer.add(ai) }

        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "AVAssetWriter failed to start"
            throw ExportError.writerFailed(msg)
        }
    }

    // MARK: - Append Buffers

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        if !hasStartedSession {
            writer.startSession(atSourceTime: pts)
            hasStartedSession = true
        }

        guard videoInput.isReadyForMoreMediaData else { return }

        // Detect timestamp gaps (screen was static — SCStream skips duplicate frames).
        // AVAssetWriter with H.264 handles sparse buffers correctly via presentation
        // timestamps: the last frame is held for the duration of the gap. No re-timestamping
        // is required; just continue appending the new buffer as-is.
        if lastVideoTime.isValid {
            let delta = CMTimeSubtract(pts, lastVideoTime)
            let maxGap = CMTime(value: 1, timescale: 5) // 200 ms
            if CMTimeCompare(delta, maxGap) > 0 {
                // Gap noted; the video will correctly show the last frame for this duration.
                // Do not attempt to fill or re-timestamp — that would require buffering the
                // previous CMSampleBuffer which violates the no-buffer-in-RAM rule.
            }
        }

        let appended = videoInput.append(sampleBuffer)
        if !appended {
            logger.error("appendVideo failed at pts=\(pts.seconds, privacy: .public) — writer status=\(self.writer.status.rawValue, privacy: .public) error=\(String(describing: self.writer.error), privacy: .public)")
        }
        lastVideoTime = pts
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard writer.status == .writing, hasStartedSession else { return }
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
        let appended = audioInput.append(sampleBuffer)
        if !appended {
            logger.error("appendAudio failed — writer status=\(self.writer.status.rawValue, privacy: .public) error=\(String(describing: self.writer.error), privacy: .public)")
        }
    }

    // MARK: - Finish / Cancel

    func finishWriting() async throws -> URL {
        // If no video frames were appended, startSession was never called.
        // AVAssetWriter.finishWriting would produce an empty/invalid file.
        // Cancel and surface a clear error so the coordinator can recover gracefully.
        //
        // NSLock.lock()/unlock() are banned in async contexts (Swift 6 strict concurrency).
        // withLock(_:) takes a synchronous closure — no await inside — so it is safe here.
        let started = lock.withLock { hasStartedSession }

        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.exportFailed(
                "No frames were captured. The recording was too short or the stream produced no output."
            )
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        let writer = self.writer
        let outputURL = self.outputURL

        return try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume(returning: outputURL)
                } else {
                    let fullError = String(describing: writer.error)
                    logger.error("finishWriting failed — status=\(writer.status.rawValue, privacy: .public) error=\(fullError, privacy: .public)")
                    let msg = writer.error?.localizedDescription ?? "Unknown error"
                    continuation.resume(throwing: ExportError.writerFailed(msg))
                }
            }
        }
    }

    /// Cancels writing immediately — used when the stream stops unexpectedly.
    /// The partial output file should be deleted by the caller.
    func cancelWriting() {
        lock.lock()
        defer { lock.unlock() }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.cancelWriting()
    }
}
