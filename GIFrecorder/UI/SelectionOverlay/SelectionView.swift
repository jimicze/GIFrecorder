import AppKit

/// Callback protocol from SelectionView to its owning window.
protocol SelectionViewProtocol: AnyObject {
    /// Called when the user commits a region.
    /// - Parameters:
    ///   - rect: The selected rect in AppKit coordinates (bottom-left origin).
    ///   - windowID: The CGWindowID of the snapped window, or nil for freehand.
    func selectionView(_ view: SelectionView,
                       didFinishSelectingRect rect: CGRect,
                       windowID: CGWindowID?)
    func selectionViewDidCancel(_ view: SelectionView)
}

/// NSView handling mouse drag (draw mode) and window hover (snap mode).
final class SelectionView: NSView {

    weak var selectionDelegate: SelectionViewProtocol?

    // MARK: State

    private enum Mode {
        case idle
        case drawing(start: NSPoint)
        case snapping
    }

    private var mode: Mode = .idle
    private var currentRect: NSRect = .zero
    private var hoveredSnapWindow: SnapWindow?
    private var snapWindows: [SnapWindow] = []

    // MARK: Tracking

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Window Snap Loading

    func loadSnapWindows() {
        guard let screen = NSScreen.main else { return }
        snapWindows = WindowSnapManager.snapWindows(for: screen)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dark overlay
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.fill(bounds)

        if currentRect.width > 2 && currentRect.height > 2 {
            drawSelection(ctx: ctx, rect: currentRect)
        } else if let snap = hoveredSnapWindow {
            guard let screen = NSScreen.main else { return }
            let r = snap.frameInScreen(screen)
            drawSnapHighlight(ctx: ctx, rect: r)
        }
    }

    private func drawSelection(ctx: CGContext, rect: NSRect) {
        // Clear the selected area
        ctx.clear(rect)

        // Dashed border
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.0)
        ctx.setLineDash(phase: 0, lengths: [8, 4])
        ctx.stroke(rect)

        // Red corner handles
        let handleSize: CGFloat = 8
        let handles: [NSRect] = [
            NSRect(x: rect.minX - handleSize / 2, y: rect.minY - handleSize / 2, width: handleSize, height: handleSize),
            NSRect(x: rect.maxX - handleSize / 2, y: rect.minY - handleSize / 2, width: handleSize, height: handleSize),
            NSRect(x: rect.minX - handleSize / 2, y: rect.maxY - handleSize / 2, width: handleSize, height: handleSize),
            NSRect(x: rect.maxX - handleSize / 2, y: rect.maxY - handleSize / 2, width: handleSize, height: handleSize),
        ]
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.setLineDash(phase: 0, lengths: [])
        for handle in handles { ctx.fill(handle) }

        // Dimensions label
        drawDimensionsLabel(ctx: ctx, rect: rect)
    }

    private func drawSnapHighlight(ctx: CGContext, rect: NSRect) {
        // Clear the snap area
        ctx.clear(rect)

        // Solid highlight border
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(3.0)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))

        drawDimensionsLabel(ctx: ctx, rect: rect)

        // Show tracking badge when window tracking is enabled
        if AppSettings.shared.windowTrackingEnabled {
            drawTrackingBadge(ctx: ctx, rect: rect)
        }
    }

    /// Draws a small "⊙ Track" pill badge in the top-right corner of the snap rect.
    private func drawTrackingBadge(ctx: CGContext, rect: NSRect) {
        let label = "⊙ Track"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let strSize = str.size()
        let hPad: CGFloat = 6
        let vPad: CGFloat = 4
        let badgeW = strSize.width + hPad * 2
        let badgeH = strSize.height + vPad * 2
        let badgeX = rect.maxX - badgeW - 8
        let badgeY = rect.maxY - badgeH - 8
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

        ctx.saveGState()
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.85).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        str.draw(at: NSPoint(x: badgeRect.minX + hPad, y: badgeRect.minY + vPad))
    }

    private func drawDimensionsLabel(ctx: CGContext, rect: NSRect) {
        let w = Int(rect.width)
        let h = Int(rect.height)
        let label = "\(w) × \(h)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()

        var labelRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.maxY + 6,
            width: size.width + 10,
            height: size.height + 4
        )
        // Keep on screen
        if labelRect.maxY > bounds.maxY { labelRect.origin.y = rect.minY - labelRect.height - 6 }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fill(labelRect)

        str.draw(at: NSPoint(x: labelRect.minX + 5, y: labelRect.minY + 2))
    }

    // MARK: Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let snap = hoveredSnapWindow {
            // Window snap mode — use this window's bounds
            guard let screen = NSScreen.main else { return }
            let rect = snap.frameInScreen(screen)
            selectionDelegate?.selectionView(self, didFinishSelectingRect: rect, windowID: snap.id)
        } else {
            // Draw mode
            mode = .drawing(start: point)
            currentRect = NSRect(origin: point, size: .zero)
            hoveredSnapWindow = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .drawing(let start) = mode else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard case .drawing = mode else { return }
        mode = .idle
        if currentRect.width > 10 && currentRect.height > 10 {
            selectionDelegate?.selectionView(self, didFinishSelectingRect: currentRect, windowID: nil)
        } else {
            currentRect = .zero
            setNeedsDisplay(bounds)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .idle = mode else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredWindow(at: point)
    }

    // MARK: Window Snap Hover

    private func updateHoveredWindow(at point: NSPoint) {
        // Find smallest window containing the point
        guard let screen = NSScreen.main else { return }
        let hit = snapWindows.filter { snap in
            snap.frameInScreen(screen).contains(point)
        }.min(by: { a, b in
            a.frame.width * a.frame.height < b.frame.width * b.frame.height
        })

        if hit?.id != hoveredSnapWindow?.id {
            hoveredSnapWindow = hit
            setNeedsDisplay(bounds)
        }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            selectionDelegate?.selectionViewDidCancel(self)
        }
    }
}
