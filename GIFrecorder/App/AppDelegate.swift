import AppKit
import Combine
import SwiftUI
import os

private let logger = Logger(subsystem: "com.gifrecorder.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var recordingPulseTimer: Timer?
    private var isPulseOn = false
    private var cancellables = Set<AnyCancellable>()

    let appState = AppState()
    let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard — the newest launch always wins.
        // Terminates any stale copies (from a previous Xcode run, a previous manual open,
        // or a leftover debug session) before finishing setup.
        // Applied in ALL build configurations: Debug builds are re-launched frequently by
        // Xcode and would otherwise accumulate stale menu-bar icons.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            logger.warning("terminating \(others.count) stale instance(s) — new launch takes over")
            others.forEach { $0.terminate() }

            // Wait (max 2 s) for all old instances to fully exit so their
            // NSStatusItems are removed from the menu bar before we add ours.
            // Blocking here is safe — no UI has been created yet.
            let deadline = Date().addingTimeInterval(2.0)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        NSApp.setActivationPolicy(.accessory)
        logger.info("applicationDidFinishLaunching")
        applyDockPolicy(settings.showDockIcon)
        setupStatusItem()
        setupPopover()
        setupGlobalHotkey()
        observeDockSetting()
    }

    private func applyDockPolicy(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    private func observeDockSetting() {
        settings.$showDockIcon
            .dropFirst()
            .sink { [weak self] show in self?.applyDockPolicy(show) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Explicitly remove the status item before the process exits so macOS
        // clears the icon from the menu bar immediately.  Without this, a ghost
        // icon can linger when we are terminated by a newer instance.
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        GlobalHotkeyManager.shared.unregister()
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        GlobalHotkeyManager.shared.onToggle = { [weak self] in
            self?.handleHotkeyToggle()
        }

        // Register immediately if enabled in settings.
        if settings.globalHotkeyEnabled {
            GlobalHotkeyManager.shared.register()
        }

        // React to the user toggling the setting on/off.
        settings.$globalHotkeyEnabled
            .dropFirst()  // skip the initial emission (handled above)
            .sink { enabled in
                if enabled {
                    GlobalHotkeyManager.shared.register()
                } else {
                    GlobalHotkeyManager.shared.unregister()
                }
            }
            .store(in: &cancellables)
    }

    private func handleHotkeyToggle() {
        switch appState.recordingState {
        case .idle:
            logger.info("hotkey — triggering beginSelection")
            // Close the popover (if open) and begin region selection.
            popover?.performClose(nil)
            Task { @MainActor in
                await RecordingCoordinator.shared.beginSelection(
                    appState: self.appState,
                    settings: self.settings
                )
            }
        case .recording:
            logger.info("hotkey — triggering stopRecording")
            // Stop the active recording.
            Task { @MainActor in
                await RecordingCoordinator.shared.stopRecording(
                    appState: self.appState,
                    settings: self.settings
                )
            }
        default:
            break  // ignore hotkey during countdown / stopping / exporting
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "GIFrecorder")
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(appState)
                .environmentObject(settings)
        )
        self.popover = popover
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Recording Indicator

    func startRecordingIndicator() {
        recordingPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pulseIcon()
        }
    }

    func stopRecordingIndicator() {
        recordingPulseTimer?.invalidate()
        recordingPulseTimer = nil
        isPulseOn = false
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.button?.image = NSImage(
                systemSymbolName: "record.circle",
                accessibilityDescription: "GIFrecorder"
            )
        }
    }

    private func pulseIcon() {
        isPulseOn.toggle()
        let name = isPulseOn ? "record.circle.fill" : "record.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "GIFrecorder")
        statusItem?.button?.image?.isTemplate = false
        if isPulseOn {
            statusItem?.button?.image = tintedImage(named: name, color: .systemRed)
        }
    }

    private func tintedImage(named: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: named, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Popover access for SwiftUI views

    /// Closes the popover programmatically. Safe to call from any context.
    func closePopover() {
        popover?.performClose(nil)
    }
}
