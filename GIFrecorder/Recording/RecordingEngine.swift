import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import os

private let logger = Logger(subsystem: "com.gifrecorder.app", category: "RecordingEngine")

/// Typed errors for the recording pipeline.
enum RecordingError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case streamSetupFailed(underlying: Error)
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission denied. Please grant access in System Settings → Privacy & Security → Screen Recording."
        case .noDisplayFound:
            return "No display available for capture."
        case .streamSetupFailed(let e):
            return "Stream setup failed: \(e.localizedDescription)"
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No recording is in progress."
        }
    }
}

/// Core recording engine. Manages SCStream lifecycle.
/// Call start(region:config:) to begin; stop() to finish.
/// Marked @unchecked Sendable because all mutations happen from the
/// @MainActor coordinator (start/stop) or via DispatchQueue.main.async
/// (unexpected-stop handler). Thread safety is ensured by usage pattern.
final class RecordingEngine: @unchecked Sendable {

    static let shared = RecordingEngine()

    private var stream: SCStream?
    private var streamDelegate: StreamDelegate?
    private var writerSession: AssetWriterSession?
    private var isActive = false

    /// Called on the main thread when the stream stops due to an unexpected error
    /// (e.g. permission revoked, display disconnected mid-recording).
    /// Set by RecordingCoordinator before each recording; cleared after stop/error.
    var onUnexpectedStop: ((Error) -> Void)?

    private init() {}

    // MARK: - Start

    func start(region: CGRect, config: RecordingConfig) async throws {
        guard !isActive else { throw RecordingError.alreadyRecording }

        logger.info("start() — region=\(region.width, privacy: .public)×\(region.height, privacy: .public) @ (\(region.origin.x, privacy: .public),\(region.origin.y, privacy: .public)) fps=\(config.fps, privacy: .public) audio=\(config.capturesAudio, privacy: .public)")

        // 0. Fast TCC pre-check — tells us definitively whether the OS will allow capture
        //    before we even try SCShareableContent.  Logged so it's visible in Xcode console.
        if #available(macOS 14.2, *) {
            let tccGranted = CGPreflightScreenCaptureAccess()
            logger.info("CGPreflightScreenCaptureAccess: \(tccGranted, privacy: .public)")
            if !tccGranted {
                logger.error("TCC screen-recording permission not granted — open System Settings → Privacy & Security → Screen & System Audio Recording and enable GIFrecorder, then quit & reopen the app once.")
                throw RecordingError.permissionDenied
            }
        }

        // 1. Get available content (displays, windows)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Log the REAL error — previously this was swallowed and everything looked like
            // a permission denial even when the root cause was something else entirely.
            logger.error("SCShareableContent failed — domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public) msg=\(error.localizedDescription, privacy: .public)")
            throw RecordingError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw RecordingError.noDisplayFound
        }

        // 2. Content filter — entire display (we crop via sourceRect)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // 3. Stream configuration
        // H.264 requires even dimensions; minimum 16px each side.
        let displayScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let captureWidth  = max(Int(region.width  * displayScale) & ~1, 16)
        let captureHeight = max(Int(region.height * displayScale) & ~1, 16)
        logger.info("computed capture size — \(captureWidth, privacy: .public)×\(captureHeight, privacy: .public)px (scale=\(displayScale, privacy: .public))")

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = captureWidth
        streamConfig.height = captureHeight
        streamConfig.capturesAudio = config.capturesAudio
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.sourceRect = normalizeRegion(region, display: display)
        streamConfig.showsCursor = false
        // NV12 (420YpCbCr8BiPlanarVideoRange) is the H.264 encoder's native pixel format.
        // Using 32BGRA requires a colour-space conversion in VideoToolbox that can fail in
        // some configurations, causing AVAssetWriterInput.append() to silently return false
        // and the writer to enter a .failed state before finishWriting is called.
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // 4. Create AVAssetWriter session — dimensions must match SCStream exactly.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifrecorder-\(UUID().uuidString).mov")

        let writer = try AssetWriterSession(
            url: tempURL,
            config: config,
            videoWidth: captureWidth,
            videoHeight: captureHeight
        )
        self.writerSession = writer

        // 5. Create SCStream + wire up error propagation
        let delegate = StreamDelegate(session: writer)
        delegate.onUnexpectedStop = { [weak self] error in
            guard let self else { return }
            logger.error("stream stopped unexpectedly: \(error.localizedDescription, privacy: .public)")
            // The stream has already stopped; clean up locally, then surface the error.
            self.isActive = false
            self.stream = nil
            self.streamDelegate = nil
            self.writerSession?.cancelWriting()
            self.writerSession = nil
            // Dispatch to main — onUnexpectedStop closure is set by @MainActor coordinator.
            DispatchQueue.main.async {
                self.onUnexpectedStop?(error)
                self.onUnexpectedStop = nil
            }
        }
        self.streamDelegate = delegate

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: delegate)
        self.stream = stream

        try stream.addStreamOutput(
            delegate, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.gifrecorder.screen", qos: .userInteractive)
        )
        if config.capturesAudio {
            try stream.addStreamOutput(
                delegate, type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.gifrecorder.audio", qos: .userInteractive)
            )
        }

        // 6. Start capture
        do {
            try await stream.startCapture()
            isActive = true
            logger.info("SCStream started successfully")
        } catch {
            // Clean up if startCapture fails
            delegate.onUnexpectedStop = nil
            self.stream = nil
            self.streamDelegate = nil
            self.writerSession?.cancelWriting()
            self.writerSession = nil
            logger.error("startCapture failed: \(error.localizedDescription, privacy: .public)")
            throw RecordingError.streamSetupFailed(underlying: error)
        }
    }

    // MARK: - Stop

    func stop() async throws -> URL {
        guard isActive, let stream, let writerSession else {
            throw RecordingError.notRecording
        }
        logger.info("stop() called")

        // Clear the unexpected-stop handler before stopping to avoid spurious callbacks.
        streamDelegate?.onUnexpectedStop = nil
        onUnexpectedStop = nil

        // Stop the stream
        try await stream.stopCapture()
        self.stream = nil
        self.streamDelegate = nil
        isActive = false

        // Finish writing
        let url = try await writerSession.finishWriting()
        self.writerSession = nil
        logger.info("recording finished — temp file: \(url.lastPathComponent, privacy: .public)")
        return url
    }

    // MARK: - Helpers

    /// Converts SelectionView rect (AppKit: bottom-left origin, points) to
    /// SCStreamConfiguration.sourceRect format (top-left origin, logical points of display).
    private func normalizeRegion(_ region: CGRect, display: SCDisplay) -> CGRect {
        let displayHeight = CGFloat(display.height)
        // AppKit origin: bottom-left → SCStream origin: top-left
        let scX = region.origin.x
        let scY = displayHeight - region.origin.y - region.height
        return CGRect(x: scX, y: scY, width: region.width, height: region.height)
    }
}
