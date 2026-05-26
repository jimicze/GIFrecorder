import AppKit

/// Protocol for receiving the selected region from SelectionWindow.
protocol SelectionWindowDelegate: AnyObject {
    /// Called when the user commits a region.
    /// - Parameters:
    ///   - rect: Selected region in AppKit coordinates.
    ///   - windowID: The CGWindowID of the snapped window, or nil for freehand.
    func selectionWindow(_ window: SelectionWindow,
                         didSelectRect rect: CGRect,
                         windowID: CGWindowID?)
    func selectionWindowDidCancel(_ window: SelectionWindow)
}

/// Full-screen transparent overlay window for region selection.
final class SelectionWindow: NSWindow {
    weak var selectionDelegate: SelectionWindowDelegate?
    private var selectionView: SelectionView?

    init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame

        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        self.isOpaque = false
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = false

        setupContentView()
        setupCursor()
    }

    // Borderless windows return NO from canBecomeKey by default, which causes
    // "-[NSWindow makeKeyWindow] returned NO from canBecomeKeyWindow" warnings
    // and prevents ESC keyDown events from being delivered.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }  // overlay — not a document window

    private func setupContentView() {
        let view = SelectionView(frame: contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        view.selectionDelegate = self
        contentView?.addSubview(view)
        self.selectionView = view
    }

    private func setupCursor() {
        NSCursor.crosshair.push()
    }

    func show() {
        makeKeyAndOrderFront(nil)
        // Pre-load window list for snap
        selectionView?.loadSnapWindows()
    }

    override func keyDown(with event: NSEvent) {
        // ESC cancels
        if event.keyCode == 53 {
            cancel()
        }
    }

    func cancel() {
        NSCursor.pop()
        orderOut(nil)
        selectionDelegate?.selectionWindowDidCancel(self)
    }
}

// MARK: - SelectionViewDelegate

extension SelectionWindow: SelectionViewProtocol {
    func selectionView(_ view: SelectionView,
                       didFinishSelectingRect rect: CGRect,
                       windowID: CGWindowID?) {
        NSCursor.pop()
        orderOut(nil)
        selectionDelegate?.selectionWindow(self, didSelectRect: rect, windowID: windowID)
    }

    func selectionViewDidCancel(_ view: SelectionView) {
        cancel()
    }
}
