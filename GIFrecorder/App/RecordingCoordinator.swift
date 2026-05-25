import AppKit
import AVKit
import CoreGraphics
import ObjectiveC
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UserNotifications
import os

private let logger = Logger(subsystem: "com.gifrecorder.app", category: "Coordinator")

/// Orchestrates the recording flow: region selection → countdown → recording → export.
@MainActor
final class RecordingCoordinator {

    static let shared = RecordingCoordinator()
    private init() {}

    private var selectionWindow: SelectionWindow?
    private var countdownWindow: CountdownWindow?
    private var currentSession: RecordingSession?
    private var selectionBridge: SelectionCoordinatorBridge?  // strong ref to delegate bridge
    private var fileSizeTimer: Timer?

    /// Weak references set at recording start so the unexpected-stop handler can reach them.
    private weak var currentAppState: AppState?
    private weak var currentSettings: AppSettings?

    // MARK: - File Size Timer

    private func stopFileSizeTimer() {
        fileSizeTimer?.invalidate()
        fileSizeTimer = nil
        currentAppState?.currentRecordingBytes = 0
    }

    // MARK: - Permission Check

    /// Checks screen recording permission and updates `appState.screenRecordingPermission`.
    ///
    /// On macOS 14.2+:
    ///   1. Fast-path: `CGPreflightScreenCaptureAccess()` — returns immediately if already granted.
    ///   2. Otherwise: `CGRequestScreenCaptureAccess()` — shows the system dialog and grants
    ///      permission to the **current running process** when the user allows.
    ///      No app restart required. This makes the Xcode debug workflow work correctly:
    ///      run from Xcode → dialog appears → allow → recording works immediately in the
    ///      same process/debug session.
    ///      If the user previously denied, the function returns false without showing the
    ///      dialog again; the banner directs them to System Settings (which requires a restart).
    /// On macOS 13.0–14.1 falls back to a lightweight `SCShareableContent` probe.
    func checkPermission(appState: AppState) async {
        #if DEBUG
        // ── DEBUG BUILDS: skip the permission banner entirely ─────────────────
        // The TCC "Quit & Reopen" restart kills the Xcode debug session.
        // In DEBUG we assume permission is granted and let SCStream enforce it:
        // if TCC is actually denied, RecordingEngine.start() throws a clear error
        // that surfaces through the normal error banner — no silent failure.
        // One-time setup: grant permission once outside Xcode, then ⌘R always works.
        appState.screenRecordingPermission = .granted
        logger.info("DEBUG: permission check bypassed — assuming granted")
        #else
        // ── RELEASE BUILDS: real TCC check ────────────────────────────────────
        if #available(macOS 14.2, *) {
            if CGPreflightScreenCaptureAccess() {
                appState.screenRecordingPermission = .granted
                logger.info("permission check: granted (preflight)")
                return
            }
            // Opens System Settings to the Screen Recording pane so the user
            // can toggle GIFrecorder on. Returns false on macOS 15 (restart required).
            let granted = CGRequestScreenCaptureAccess()
            appState.screenRecordingPermission = granted ? .granted : .denied
            logger.info("permission request: \(granted ? "granted" : "denied", privacy: .public)")
            return
        }
        // macOS 13.0–14.1 fallback: SCShareableContent probe.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            appState.screenRecordingPermission = .granted
            logger.info("permission check (SCShareableContent probe): granted")
        } catch {
            appState.screenRecordingPermission = .denied
            logger.warning("permission check (SCShareableContent probe): denied — \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    // MARK: - Begin Region Selection

    func beginSelection(appState: AppState, settings: AppSettings) async {
        let window = SelectionWindow()
        let bridge = SelectionCoordinatorBridge(coordinator: self, appState: appState, settings: settings)
        self.selectionBridge = bridge
        window.selectionDelegate = bridge
        self.selectionWindow = window
        window.show()
    }

    // MARK: - Cancel (UI-initiated)

    /// Cancels an in-progress region selection or countdown and resets to idle.
    func cancel(appState: AppState) {
        if selectionWindow != nil {
            selectionWindow?.cancel()
            selectionWindow = nil
            selectionBridge = nil
            // State reset happens via selectionWindowDidCancel delegate callback
        } else if countdownWindow != nil {
            countdownWindow?.cancelCountdown()
            countdownWindow = nil
            currentSession = nil
            appState.recordingState = .idle
        }
    }

    // MARK: - After Region Selected

    func regionSelected(_ rect: CGRect, appState: AppState, settings: AppSettings) {
        selectionWindow = nil
        selectionBridge = nil

        logger.info("region selected — \(rect.width, privacy: .public)×\(rect.height, privacy: .public) @ (\(rect.origin.x, privacy: .public),\(rect.origin.y, privacy: .public))")

        let config = settings.recordingConfig
        let session = RecordingSession(region: rect, config: config)
        currentSession = session

        if settings.showCountdown {
            appState.recordingState = .countdown(3)

            let countdown = CountdownWindow(
                countdownFrom: 3,
                onTick: { [weak self] value in
                    // onTick fires on the main thread (dispatched in CountdownWindow)
                    self?.currentAppState?.recordingState = .countdown(value)
                },
                onFinished: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        self.countdownWindow = nil
                        await self.startRecording(
                            region: rect,
                            config: config,
                            appState: appState,
                            settings: settings
                        )
                    }
                }
            )
            self.countdownWindow = countdown
            countdown.startCountdown()
        } else {
            Task {
                await startRecording(region: rect, config: config, appState: appState, settings: settings)
            }
        }
    }

    // MARK: - Start Recording

    private func startRecording(
        region: CGRect,
        config: RecordingConfig,
        appState: AppState,
        settings: AppSettings
    ) async {
        appState.recordingState = .recording

        // Store weak refs for the unexpected-stop handler.
        currentAppState = appState
        currentSettings = settings

        // Wire unexpected-stop before calling start so no events can be missed.
        RecordingEngine.shared.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                self?.handleUnexpectedStreamStop(error: error)
            }
        }

        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.startRecordingIndicator()
        }

        do {
            try await RecordingEngine.shared.start(region: region, config: config)
            fileSizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self, self.fileSizeTimer != nil else { return }
                self.currentAppState?.currentRecordingBytes = RecordingEngine.shared.currentRecordingBytes
            }
        } catch {
            RecordingEngine.shared.onUnexpectedStop = nil
            currentAppState = nil
            currentSettings = nil
            currentSession = nil
            appState.recordingState = .idle
            logger.error("RecordingEngine.start failed: \(error.localizedDescription, privacy: .public)")
            appState.setError(error.localizedDescription)
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.stopRecordingIndicator()
            }
        }
    }

    // MARK: - Stop Recording

    func stopRecording(appState: AppState, settings: AppSettings) async {
        guard case .recording = appState.recordingState else { return }
        logger.info("stopRecording() — initiating stop")

        stopFileSizeTimer()
        appState.recordingState = .stopping

        // Clear the unexpected-stop handler — we're stopping intentionally.
        RecordingEngine.shared.onUnexpectedStop = nil

        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.stopRecordingIndicator()
        }

        do {
            let sourceURL = try await RecordingEngine.shared.stop()

            // Determine default export format: prefer the format baked into this session's config,
            // then fall back to the global default setting.
            let defaultFormat = currentSession?.config.exportFormat ?? settings.defaultFormat

            // Show save panel — synchronous modal; NSApp.activate brings it to front.
            let destinationURL = showSavePanel(
                defaultName: defaultFilename(),
                format: defaultFormat,
                suggestedDirectory: settings.defaultSaveDirectory
            )

            currentSession = nil
            currentAppState = nil
            currentSettings = nil

            guard let destinationURL else {
                // User cancelled save; clean up temp file
                try? FileManager.default.removeItem(at: sourceURL)
                appState.recordingState = .idle
                return
            }

            // Present trim sheet if enabled.
            var trimRange: TrimRange?
            if settings.showTrimUI {
                do {
                    trimRange = try await presentTrimSheet(for: sourceURL)
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: sourceURL)
                    appState.recordingState = .idle
                    return
                } catch {
                    // Unexpected error — continue without trim.
                }
            }

            // Export
            let format = formatFromExtension(destinationURL) ?? defaultFormat
            logger.info("exporting — format=\(format.rawValue, privacy: .public) dest=\(destinationURL.lastPathComponent, privacy: .public)")
            appState.recordingState = .exporting(format)
            appState.exportProgress = 0

            try await ExportManager.shared.export(
                from: sourceURL,
                to: format,
                destination: destinationURL,
                timeRange: trimRange?.cmTimeRange
            ) { progress in
                DispatchQueue.main.async {
                    appState.exportProgress = progress
                }
            }

            // Cleanup temp
            try? FileManager.default.removeItem(at: sourceURL)

            appState.exportedFileURL = destinationURL
            appState.exportProgress = 1
            appState.recordingState = .idle
            logger.info("export complete — \(destinationURL.lastPathComponent, privacy: .public)")

            showExportNotification(url: destinationURL)

            // Generate thumbnail off the main actor to avoid blocking UI.
            let thumbnailURL = destinationURL
            let thumbnailFormat = format
            Task {
                let thumbnail = await ThumbnailGenerator.generate(from: thumbnailURL, format: thumbnailFormat)
                await MainActor.run {
                    // Guard against stale: only update if this is still the current export.
                    if appState.exportedFileURL == thumbnailURL {
                        appState.lastExportThumbnail = thumbnail
                    }
                }
            }

            // Auto-copy to clipboard if enabled.
            if AppSettings.shared.autoCopyOnExport {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([destinationURL as NSURL])
            }

        } catch {
            currentSession = nil
            currentAppState = nil
            currentSettings = nil
            appState.recordingState = .idle
            logger.error("stopRecording pipeline error: \(error.localizedDescription, privacy: .public)")
            appState.setError(error.localizedDescription)
        }
    }

    // MARK: - Unexpected Stop Handler

    /// Called by `RecordingEngine.onUnexpectedStop` via a `@MainActor` Task.
    private func handleUnexpectedStreamStop(error: Error) {
        // RecordingEngine already cancelled writing internally.
        logger.error("unexpected stream stop: \(error.localizedDescription, privacy: .public)")
        stopFileSizeTimer()
        currentSession = nil
        currentAppState?.recordingState = .idle
        currentAppState?.setError("Recording stopped unexpectedly: \(error.localizedDescription)")
        currentAppState = nil
        currentSettings = nil
        RecordingEngine.shared.onUnexpectedStop = nil
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.stopRecordingIndicator()
        }
    }

    // MARK: - Cancel Selection

    func cancelSelection() {
        selectionWindow?.cancel()
        selectionWindow = nil
        // State reset is handled by bridge
    }

    // MARK: - Helpers

    /// Shows a modal NSSavePanel on the main thread.
    /// Activates the app first so the panel appears in front of other apps.
    /// Returns the chosen URL, or nil if the user cancelled.
    private func showSavePanel(defaultName: String, format: ExportFormat, suggestedDirectory: URL?) -> URL? {
        // Bring GIFrecorder to the front — essential for LSUIElement apps that
        // have no Dock icon and might not be the active application when recording stops.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = ExportFormat.allCases.map { $0.utType }
        panel.directoryURL = suggestedDirectory
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = defaultName + "." + format.fileExtension

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "recording-\(formatter.string(from: Date()))"
    }

    private func formatFromExtension(_ url: URL) -> ExportFormat? {
        ExportFormat(rawValue: url.pathExtension.lowercased())
    }

    private func showExportNotification(url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Recording saved"
        content.body = url.lastPathComponent
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Trim Sheet

    @MainActor
    private func presentTrimSheet(for url: URL) async throws -> TrimRange? {
        try await withCheckedThrowingContinuation { continuation in
            // Wrap continuation to guarantee at-most-once resume.
            var resumed = false
            let resume: (Result<TrimRange?, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let v): continuation.resume(returning: v)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            let delegate = TrimWindowDelegate { resume(.failure(CancellationError())) }
            var window: NSWindow?

            let sheet = TrimSheet(
                sourceURL: url,
                onConfirm: { [weak window] trimRange in
                    window?.close()
                    resume(.success(trimRange))
                },
                onCancel: { [weak window] in
                    window?.close()
                    resume(.failure(CancellationError()))
                }
            )

            let hosting = NSHostingController(rootView: sheet)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Trim Recording"
            w.styleMask = [.titled, .closable]
            w.delegate = delegate
            w.center()
            window = w
            // Keep delegate alive for the window's lifetime.
            objc_setAssociatedObject(w, &TrimWindowDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Bridge (avoids @MainActor on NSObject subclass)

/// Bridges SelectionWindow delegate callbacks (which can fire on any thread) to MainActor.
private final class SelectionCoordinatorBridge: NSObject, SelectionWindowDelegate {
    private let coordinator: RecordingCoordinator
    private let appState: AppState
    private let settings: AppSettings

    init(coordinator: RecordingCoordinator, appState: AppState, settings: AppSettings) {
        self.coordinator = coordinator
        self.appState = appState
        self.settings = settings
    }

    func selectionWindow(_ window: SelectionWindow, didSelectRect rect: CGRect) {
        Task { @MainActor in
            self.coordinator.regionSelected(rect, appState: self.appState, settings: self.settings)
        }
    }

    func selectionWindowDidCancel(_ window: SelectionWindow) {
        Task { @MainActor in
            self.appState.recordingState = .idle
        }
    }
}

// MARK: - TrimWindowDelegate

/// NSWindowDelegate that fires a callback when the window is about to close.
private final class TrimWindowDelegate: NSObject, NSWindowDelegate {
    static var key: UInt8 = 0
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
