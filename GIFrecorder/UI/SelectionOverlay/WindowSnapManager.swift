import AppKit
import ScreenCaptureKit

/// Represents a snap-able application window.
struct SnapWindow: Identifiable {
    let id: CGWindowID
    let ownerName: String
    let title: String?
    /// Raw Quartz window-server coordinates: origin is top-left of the primary display, Y grows downward.
    let frame: CGRect

    /// Converts the Quartz frame to AppKit/NSView coordinates for the given screen.
    /// AppKit has origin at bottom-left with Y growing upward.
    func frameInScreen(_ screen: NSScreen) -> CGRect {
        let screenHeight = screen.frame.height
        return CGRect(
            x: frame.origin.x,
            y: screenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

/// Enumerates on-screen windows for the snap feature.
/// Uses CGWindowListCopyWindowInfo for speed (no async required).
final class WindowSnapManager {

    static func snapWindows(for screen: NSScreen) -> [SnapWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { info -> SnapWindow? in
            guard
                let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,  // only normal-level windows
                let ownerName = info[kCGWindowOwnerName as String] as? String
            else { return nil }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0

            guard w > 50, h > 50 else { return nil }

            // Store raw Quartz coordinates (top-left origin, Y grows down).
            // frameInScreen(_:) performs the single correct conversion to AppKit space.
            let frame = CGRect(x: x, y: y, width: w, height: h)

            let title = info[kCGWindowName as String] as? String

            return SnapWindow(id: windowID, ownerName: ownerName, title: title, frame: frame)
        }
    }
}
