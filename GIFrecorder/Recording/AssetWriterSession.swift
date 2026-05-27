@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox
import os

private let logger = Logger(subsystem: "com.lasakondrej.gifrecorder", category: "AssetWriterSession")

/// Wraps AVAssetWriter to receive CMSampleBuffers from SCStream.
/// Writes video (H.264) and audio (AAC) to a .mov file.
final class AssetWriterSession {

    // MARK: - Properties

    let outputURL: URL

    /// Approximate size of the in-progress recording file, in bytes.
    /// Returns 0 if the file does not yet exist or metadata read fails.
    var estimatedFileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let declaredVideoWidth: Int
    private let declaredVideoHeight: Int

    private var hasStartedSession = false
    private var lastVideoTime: CMTime = .invalid
    private var lastPixelBuffer: CVPixelBuffer?   // retained for SCStream idle-frame reuse
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
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
            ]
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
        self.declaredVideoWidth = videoWidth
        self.declaredVideoHeight = videoHeight

        // Add inputs to writer
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        if let ai = audioInput, writer.canAdd(ai) { writer.add(ai) }

        flog("AssetWriterSession.init — videoWidth=\(videoWidth) videoHeight=\(videoHeight) url=\(url.lastPathComponent)")
        guard writer.startWriting() else {
            let err = writer.error as NSError?
            let msg = err?.localizedDescription ?? "AVAssetWriter failed to start"
            flog("startWriting FAILED — domain=\(err?.domain ?? "nil") code=\(err?.code ?? -1) msg=\(msg) userInfo=\(err?.userInfo ?? [:])")
            throw ExportError.writerFailed(msg)
        }
        flog("startWriting OK — status=\(writer.status.rawValue)")
    }

    // MARK: - Append Buffers

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard writer.status == .writing else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        // SCStream delivers two kinds of screen output buffers:
        //   • complete frames – CVPixelBuffer present (screen content changed)
        //   • idle frames     – no CVPixelBuffer (screen content unchanged)
        // For idle frames we re-use the last complete pixel buffer so that
        // the output video maintains a consistent frame rate.
        // We also use the pixel-buffer adaptor (not videoInput.append(_:)) to
        // bypass the CMFormatDescription that caused AVFoundationErrorDomain
        // -11800 / NSOSStatusErrorDomain -16122 with videoInput.append.
        let pixelBuffer: CVPixelBuffer
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lastPixelBuffer = pb
            pixelBuffer = pb
        } else if let last = lastPixelBuffer {
            // Idle frame: repeat last complete frame to preserve frame rate
            pixelBuffer = last
        } else {
            // No complete frame received yet; skip
            return
        }

        if !hasStartedSession {
            writer.startSession(atSourceTime: pts)
            hasStartedSession = true
            let bw = CVPixelBufferGetWidth(pixelBuffer)
            let bh = CVPixelBufferGetHeight(pixelBuffer)
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let match = (bw == declaredVideoWidth && bh == declaredVideoHeight) ? "MATCH" : "MISMATCH"
            flog("first video frame — buffer=\(bw)×\(bh)px fmt=\(fmt) declared=\(declaredVideoWidth)×\(declaredVideoHeight) \(match)")
            if let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let extensions = CMFormatDescriptionGetExtensions(fmtDesc) as? [String: Any]
                flog("first frame CMFormatDescription extensions=\(String(describing: extensions))")
            }
        }

        guard videoInput.isReadyForMoreMediaData else { return }

        let appended = pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts)
        if !appended {
            let err = writer.error as NSError?
            flog("appendVideo FAILED — pts=\(pts.seconds) writer.status=\(writer.status.rawValue) domain=\(err?.domain ?? "nil") code=\(err?.code ?? -1) msg=\(err?.localizedDescription ?? "nil") userInfo=\(err?.userInfo ?? [:])")
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
                    flog("finishWriting OK — \(outputURL.lastPathComponent)")
                    continuation.resume(returning: outputURL)
                } else {
                    let err = writer.error as NSError?
                    let msg = err?.localizedDescription ?? "Unknown error"
                    flog("finishWriting FAILED — status=\(writer.status.rawValue) domain=\(err?.domain ?? "nil") code=\(err?.code ?? -1) msg=\(msg)")
                    flog("finishWriting FAILED — userInfo=\(err?.userInfo ?? [:])")
                    logger.error("finishWriting failed — status=\(writer.status.rawValue, privacy: .public) error=\(String(describing: writer.error), privacy: .public)")
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
