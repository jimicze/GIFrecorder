import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import os

private let logger = Logger(subsystem: "com.lasakondrej.gifrecorder", category: "RecordingEngine")

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

final class RecordingEngine: @unchecked Sendable {

    static let shared = RecordingEngine()

    private var stream: SCStream?
    private var streamDelegate: StreamDelegate?
    private var writerSession: AssetWriterSession?
    private var isActive = false

    var onUnexpectedStop: ((Error) -> Void)?

    // MARK: - Multi-segment state (window tracking)

    /// Completed segment temp URLs. Non-empty only when window tracking triggered restartCapture.
    private var segments: [URL] = []
    /// True when capture is intentionally paused (freeze-frame mode).
    private var isPaused = false
    /// True when restartCapture is in progress; prevents concurrent restarts.
    private var isRestarting = false
    /// Stored capture parameters so restartCapture can rebuild the stream.
    private var captureDisplay: SCDisplay?
    private var captureScreen: NSScreen?
    private var captureConfig: RecordingConfig?
    private var captureRegion: CGRect = .zero

    var currentRecordingBytes: Int64 {
        writerSession?.estimatedFileSize ?? 0
    }

    private init() {}

    // MARK: - Start

    func start(region: CGRect, config: RecordingConfig) async throws {
        guard !isActive else { throw RecordingError.alreadyRecording }

        logger.info("start() — region=\(region.width, privacy: .public)×\(region.height, privacy: .public) @ (\(region.origin.x, privacy: .public),\(region.origin.y, privacy: .public)) fps=\(config.fps, privacy: .public) audio=\(config.capturesAudio, privacy: .public)")

        if #available(macOS 14.2, *) {
            let tccGranted = CGPreflightScreenCaptureAccess()
            logger.info("CGPreflightScreenCaptureAccess: \(tccGranted, privacy: .public)")
            if !tccGranted {
                logger.error("TCC screen-recording permission not granted — open System Settings → Privacy & Security → Screen & System Audio Recording and enable GIFrecorder, then quit & reopen the app once.")
                throw RecordingError.permissionDenied
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("SCShareableContent failed — domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public) msg=\(error.localizedDescription, privacy: .public)")
            throw RecordingError.permissionDenied
        }

        let captureScreen = NSScreen.main ?? NSScreen.screens[0]
        let screenDisplayID = captureScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let matchedDisplay = screenDisplayID.flatMap { id in content.displays.first { $0.displayID == id } }
        guard let display = matchedDisplay ?? content.displays.first else {
            throw RecordingError.noDisplayFound
        }
        flog("display selection — all displays: \(content.displays.map { "\($0.displayID)(\($0.width)×\($0.height))" }.joined(separator: ", "))")
        flog("display selection — NSScreen.main displayID=\(screenDisplayID.map(String.init) ?? "nil") → chose SCDisplay \(display.displayID) (\(display.width)×\(display.height)px)")
        flog("captureScreen.frame=\(captureScreen.frame) scale=\(captureScreen.backingScaleFactor)")

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let displayScale = captureScreen.backingScaleFactor
        let captureWidth  = max(Int(region.width  * displayScale) & ~1, 16)
        let captureHeight = max(Int(region.height * displayScale) & ~1, 16)
        flog("captureSize=\(captureWidth)×\(captureHeight)px  displayScale=\(displayScale)")

        let sourceRect = normalizeRegion(region, displayHeightInPoints: captureScreen.frame.height)
        flog("sourceRect=(\(sourceRect.origin.x),\(sourceRect.origin.y)) \(sourceRect.width)×\(sourceRect.height)pts  displayHeightPts=\(captureScreen.frame.height)")

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = captureWidth
        streamConfig.height = captureHeight
        streamConfig.capturesAudio = config.capturesAudio
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.sourceRect = sourceRect
        streamConfig.showsCursor = false
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifrecorder-\(UUID().uuidString).mov")

        let writer = try AssetWriterSession(
            url: tempURL,
            config: config,
            videoWidth: captureWidth,
            videoHeight: captureHeight
        )
        self.writerSession = writer

        let delegate = StreamDelegate(session: writer)
        delegate.onUnexpectedStop = { [weak self] error in
            guard let self else { return }
            logger.error("stream stopped unexpectedly: \(error.localizedDescription, privacy: .public)")
            self.isActive = false
            self.stream = nil
            self.streamDelegate = nil
            self.writerSession?.cancelWriting()
            self.writerSession = nil
            // Clean up any in-progress segments
            for url in self.segments { try? FileManager.default.removeItem(at: url) }
            self.segments = []
            self.captureDisplay = nil
            self.captureScreen = nil
            self.captureConfig = nil
            self.captureRegion = .zero
            self.isPaused = false
            self.isRestarting = false
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
            sampleHandlerQueue: DispatchQueue(label: "com.lasakondrej.gifrecorder.screen", qos: .userInteractive)
        )
        if config.capturesAudio {
            try stream.addStreamOutput(
                delegate, type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.lasakondrej.gifrecorder.audio", qos: .userInteractive)
            )
        }

        do {
            try await stream.startCapture()
            isActive = true
            // Store params for restartCapture
            self.captureDisplay = display
            self.captureScreen = captureScreen
            self.captureConfig = config
            self.captureRegion = region
            self.segments = []
            self.isPaused = false
            self.isRestarting = false
            logger.info("SCStream started successfully")
        } catch {
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

        // Finish the final (or only) segment
        let finalURL = try await writerSession.finishWriting()
        self.writerSession = nil
        segments.append(finalURL)

        let allSegments = segments
        segments = []
        captureDisplay = nil
        captureScreen = nil
        captureConfig = nil
        captureRegion = .zero
        isPaused = false
        isRestarting = false

        logger.info("recording finished — \(allSegments.count) segment(s)")
        flog("stop — \(allSegments.count) segment(s)")

        if allSegments.count == 1 {
            return allSegments[0]
        }

        // Multiple segments — stitch them into one .mov
        let stitchedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifrecorder-stitched-\(UUID().uuidString).mov")

        do {
            try await SegmentStitcher.stitch(allSegments, outputURL: stitchedURL)
            flog("stop — stitched \(allSegments.count) segments → \(stitchedURL.lastPathComponent)")
            return stitchedURL
        } catch {
            flog("stop — stitching failed: \(error.localizedDescription); returning first segment")
            // Clean up unused segments
            for (idx, url) in allSegments.enumerated() where idx > 0 {
                try? FileManager.default.removeItem(at: url)
            }
            return allSegments[0]
        }
    }

    // MARK: - Window Tracking Support

    /// Marks capture as paused. The AssetWriterSession's idle-frame mechanism
    /// automatically repeats the last pixel buffer, so the output freezes at the
    /// last complete frame with no further changes needed here.
    func pauseCapture() {
        isPaused = true
        flog("pauseCapture — frozen on last frame (isActive=\(isActive))")
    }

    /// Updates the capture region for a **position-only** change (no dimension change).
    /// Debounce is handled upstream by WindowTracker; this method fires `updateConfiguration`
    /// directly. Falls back to `restartCapture` if `updateConfiguration` fails.
    func resumeCapture(newRegion: CGRect) async {
        guard isActive, let stream, let screen = captureScreen, let config = captureConfig else {
            return
        }

        let displayScale = screen.backingScaleFactor
        let captureWidth  = max(Int(newRegion.width  * displayScale) & ~1, 16)
        let captureHeight = max(Int(newRegion.height * displayScale) & ~1, 16)
        let sourceRect = normalizeRegion(newRegion, displayHeightInPoints: screen.frame.height)

        let newConfig = SCStreamConfiguration()
        newConfig.width = captureWidth
        newConfig.height = captureHeight
        newConfig.capturesAudio = config.capturesAudio
        newConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        newConfig.sourceRect = sourceRect
        newConfig.showsCursor = false
        newConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        do {
            try await stream.updateConfiguration(newConfig)
            captureRegion = newRegion
            isPaused = false
            flog("resumeCapture — moved to \(newRegion.origin.x),\(newRegion.origin.y) \(newRegion.width)×\(newRegion.height)")
        } catch {
            flog("resumeCapture — updateConfiguration failed: \(error.localizedDescription); falling back to restartCapture")
            do {
                try await restartCapture(newRegion: newRegion)
            } catch {
                flog("resumeCapture — restartCapture fallback also failed: \(error.localizedDescription)")
            }
        }
    }

    /// Finishes the current segment, starts a new stream at the new dimensions,
    /// and begins a new `AssetWriterSession`. Used when the tracked window is resized
    /// or reappears after disappearing.
    func restartCapture(newRegion: CGRect) async throws {
        guard isActive, !isRestarting,
              let screen = captureScreen,
              let config = captureConfig,
              let display = captureDisplay else {
            throw RecordingError.notRecording
        }

        isRestarting = true
        defer { isRestarting = false }

        // 1. Freeze current output
        pauseCapture()

        // 2. Finish current segment
        streamDelegate?.onUnexpectedStop = nil
        if let currentSession = writerSession {
            let segURL = try await currentSession.finishWriting()
            segments.append(segURL)
            self.writerSession = nil
            flog("restartCapture — segment \(segments.count) saved: \(segURL.lastPathComponent)")
        }

        // 3. Stop current stream
        if let oldStream = stream {
            try? await oldStream.stopCapture()
            self.stream = nil
            self.streamDelegate = nil
        }

        // 4. Compute new dimensions
        let displayScale = screen.backingScaleFactor
        let captureWidth  = max(Int(newRegion.width  * displayScale) & ~1, 16)
        let captureHeight = max(Int(newRegion.height * displayScale) & ~1, 16)
        let sourceRect = normalizeRegion(newRegion, displayHeightInPoints: screen.frame.height)

        // 5. Create new AssetWriterSession
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifrecorder-\(UUID().uuidString).mov")
        let newSession = try AssetWriterSession(
            url: tempURL,
            config: config,
            videoWidth: captureWidth,
            videoHeight: captureHeight
        )
        self.writerSession = newSession

        // 6. Build new stream configuration
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = captureWidth
        streamConfig.height = captureHeight
        streamConfig.capturesAudio = config.capturesAudio
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.sourceRect = sourceRect
        streamConfig.showsCursor = false
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let delegate = StreamDelegate(session: newSession)
        delegate.onUnexpectedStop = { [weak self] error in
            guard let self else { return }
            self.isActive = false
            self.stream = nil
            self.streamDelegate = nil
            self.writerSession?.cancelWriting()
            self.writerSession = nil
            for url in self.segments { try? FileManager.default.removeItem(at: url) }
            self.segments = []
            self.captureDisplay = nil
            self.captureScreen = nil
            self.captureConfig = nil
            self.captureRegion = .zero
            self.isPaused = false
            self.isRestarting = false
            DispatchQueue.main.async {
                self.onUnexpectedStop?(error)
                self.onUnexpectedStop = nil
            }
        }
        self.streamDelegate = delegate

        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: delegate)
        self.stream = newStream

        try newStream.addStreamOutput(
            delegate, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.lasakondrej.gifrecorder.screen", qos: .userInteractive)
        )
        if config.capturesAudio {
            try newStream.addStreamOutput(
                delegate, type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.lasakondrej.gifrecorder.audio", qos: .userInteractive)
            )
        }

        // 7. Start new stream
        do {
            try await newStream.startCapture()
            captureRegion = newRegion
            isPaused = false
            flog("restartCapture — new stream started at \(newRegion.width)×\(newRegion.height), total segments so far=\(segments.count + 1)")
        } catch {
            delegate.onUnexpectedStop = nil
            self.stream = nil
            self.streamDelegate = nil
            self.writerSession?.cancelWriting()
            self.writerSession = nil
            self.isActive = false
            for url in self.segments { try? FileManager.default.removeItem(at: url) }
            self.segments = []
            self.captureDisplay = nil
            self.captureScreen = nil
            self.captureConfig = nil
            self.captureRegion = .zero
            self.isPaused = false
            throw RecordingError.streamSetupFailed(underlying: error)
        }
    }

    // MARK: - Helpers

    private func normalizeRegion(_ region: CGRect, displayHeightInPoints: CGFloat) -> CGRect {
        let scX = region.origin.x
        let scY = displayHeightInPoints - region.origin.y - region.height
        return CGRect(x: scX, y: scY, width: region.width, height: region.height)
    }
}
