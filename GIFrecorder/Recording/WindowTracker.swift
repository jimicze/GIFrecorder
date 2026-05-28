import AppKit
import CoreGraphics

/// Polls window bounds via CGWindowListCopyWindowInfo every 100ms and emits semantic events.
/// Delivers events on the main thread. Does not know about SCStream or AVAssetWriter.
final class WindowTracker {

    // MARK: - Events

    enum Event {
        case moved(newRegion: CGRect)       // position changed, size unchanged (debounced)
        case resized(newRegion: CGRect)     // size changed (may also have moved)
        case disappeared                    // window gone or minimised
        case reappeared(newRegion: CGRect)  // window back after disappearing
    }

    // MARK: - Public Interface

    /// Delivered on the main thread.
    var onEvent: ((Event) -> Void)?

    // MARK: - Private State

    private let windowID: CGWindowID
    private let screen: NSScreen
    /// Last confirmed window position in Quartz coordinates (top-left origin, Y grows down).
    private var lastKnownFrame: CGRect
    /// True while the window is absent from the window list.
    private var isDisappeared = false
    private var pollTimer: Timer?

    // Debounce state for .moved events.
    // We fire .moved only after the position has been stable for ≥2 consecutive poll ticks (~200ms).
    private var pendingMoveFrame: CGRect?   // Quartz frame of the pending move
    private var pendingMoveTick: Int = 0    // consecutive stable ticks since the move was first seen

    // Debounce state for .resized events.
    // We fire .resized only after the size has been stable for ≥5 consecutive poll ticks (~500ms).
    // This prevents rapid restartCapture chains during a live resize gesture, giving SCKit's audio
    // subsystem enough time to initialise in the new segment (startup latency ~200–500ms).
    private var pendingResizeFrame: CGRect? // Quartz frame of the pending resize
    private var pendingResizeTick: Int = 0  // consecutive stable ticks since the resize was first seen

    // MARK: - Init

    /// - Parameters:
    ///   - windowID: The CGWindowID of the window to track.
    ///   - initialQuartzFrame: The window's bounds at tracking start, in Quartz coordinates.
    ///   - screen: The NSScreen the window lives on (for coordinate conversion to AppKit).
    init(windowID: CGWindowID, initialQuartzFrame: CGRect, screen: NSScreen) {
        self.windowID = windowID
        self.lastKnownFrame = initialQuartzFrame
        self.screen = screen
    }

    // MARK: - Lifecycle

    /// Starts the 100ms polling timer on the main RunLoop. Call after RecordingEngine.start() succeeds.
    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Invalidates the timer. Safe to call multiple times.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingMoveFrame = nil
        pendingMoveTick = 0
        pendingResizeFrame = nil
        pendingResizeTick = 0
    }

    // MARK: - Polling

    private func poll() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            // Could not enumerate windows — treat as disappeared
            fireDisappearedIfNeeded()
            return
        }

        // Find our window in the list
        let entry = list.first { info in
            (info[kCGWindowNumber as String] as? CGWindowID) == windowID
        }

        guard let info = entry,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            // Window not found in the on-screen list — disappeared or minimised
            fireDisappearedIfNeeded()
            return
        }

        let x = boundsDict["X"] ?? 0
        let y = boundsDict["Y"] ?? 0
        let w = boundsDict["Width"] ?? 0
        let h = boundsDict["Height"] ?? 0
        let newFrame = CGRect(x: x, y: y, width: w, height: h)
        let newRegion = quartzToAppKit(newFrame)

        if isDisappeared {
            // Window is back
            isDisappeared = false
            lastKnownFrame = newFrame
            pendingMoveFrame = nil
            pendingMoveTick = 0
            pendingResizeFrame = nil
            pendingResizeTick = 0
            onEvent?(.reappeared(newRegion: newRegion))
            return
        }

        let sizeChanged = abs(newFrame.width  - lastKnownFrame.width)  > 2
                       || abs(newFrame.height - lastKnownFrame.height) > 2
        let positionChanged = abs(newFrame.origin.x - lastKnownFrame.origin.x) > 2
                           || abs(newFrame.origin.y - lastKnownFrame.origin.y) > 2

        if sizeChanged {
            // Debounce: fire .resized only after 5 stable ticks (~500ms) at the new size.
            // This prevents rapid restartCapture chains during live resize gestures and ensures
            // each recorded segment is long enough for SCKit audio startup (~200–500ms).
            if let pending = pendingResizeFrame,
               abs(newFrame.width  - pending.width)  <= 2,
               abs(newFrame.height - pending.height) <= 2 {
                // Same size as last tick — increment stable counter
                pendingResizeTick += 1
                if pendingResizeTick >= 5 {
                    lastKnownFrame = newFrame
                    pendingResizeFrame = nil
                    pendingResizeTick = 0
                    pendingMoveFrame = nil
                    pendingMoveTick = 0
                    onEvent?(.resized(newRegion: newRegion))
                }
            } else {
                // New size seen for the first time (or size still changing) — start/restart debounce
                pendingResizeFrame = newFrame
                pendingResizeTick = 1
            }
        } else if positionChanged {
            // Debounce: fire .moved only after 2 stable ticks (~200ms) at the new position.
            if let pending = pendingMoveFrame,
               abs(newFrame.origin.x - pending.origin.x) <= 2,
               abs(newFrame.origin.y - pending.origin.y) <= 2 {
                // Same position as last tick — increment stable counter
                pendingMoveTick += 1
                if pendingMoveTick >= 2 {
                    lastKnownFrame = newFrame
                    pendingMoveFrame = nil
                    pendingMoveTick = 0
                    onEvent?(.moved(newRegion: newRegion))
                }
            } else {
                // New position seen for the first time — start debounce
                pendingMoveFrame = newFrame
                pendingMoveTick = 1
            }
        }
        // No change — do nothing
    }

    // MARK: - Helpers

    private func fireDisappearedIfNeeded() {
        if !isDisappeared {
            isDisappeared = true
            pendingMoveFrame = nil
            pendingMoveTick = 0
            pendingResizeFrame = nil
            pendingResizeTick = 0
            onEvent?(.disappeared)
        }
    }

    /// Converts a Quartz frame (top-left origin, Y grows down) to AppKit coordinates
    /// (bottom-left origin, Y grows up) for the configured screen.
    private func quartzToAppKit(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: screen.frame.height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
