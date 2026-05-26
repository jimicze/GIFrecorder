import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            actionsSection
            Divider()
            footerSection
        }
        .frame(width: 280)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .task {
            // Refresh permission status every time the popover opens,
            // so changes made in System Settings are picked up immediately.
            await RecordingCoordinator.shared.checkPermission(appState: appState)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "record.circle.fill")
                .foregroundColor(.red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("GIFrecorder")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var statusText: String {
        switch appState.recordingState {
        case .idle: return "Ready to record"
        case .selectingRegion: return "Select region..."
        case .countdown(let n): return "Starting in \(n)..."
        case .recording:
            if appState.currentRecordingBytes > 0 {
                let formatted = ByteCountFormatter.string(
                    fromByteCount: appState.currentRecordingBytes,
                    countStyle: .file
                )
                return "Recording... ~\(formatted)"
            }
            return "Recording..."
        case .stopping: return "Stopping..."
        case .exporting(let fmt): return "Exporting \(fmt.displayName)..."
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 4) {
            // Permission banner takes priority over recording controls.
            if appState.screenRecordingPermission == .denied {
                permissionView
            } else if case .recording = appState.recordingState {
                stopButton
            } else if case .idle = appState.recordingState {
                recordButton
            } else if case .exporting = appState.recordingState {
                exportProgressView
            } else if case .selectingRegion = appState.recordingState {
                cancelButton(label: "Cancel Selection")
            } else if case .countdown = appState.recordingState {
                cancelButton(label: "Cancel Countdown")
            } else {
                progressIndicator
            }

            if let error = appState.lastError {
                errorView(error)
            }

            if let url = appState.exportedFileURL {
                lastExportView(url)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Permission View

    private var permissionView: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording Required")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Grant access in System Settings, then quit and reopen the app. This is required once — every relaunch after that works automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(action: openScreenRecordingSettings) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Open System Settings")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button(action: quitAndRelaunch) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Relaunch")
                    }
                }
                .buttonStyle(.bordered)
                .help("Quit and reopen the app so the new permission takes effect")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Relaunches the app so the newly-granted Screen Recording permission takes effect.
    /// The permission is stored in TCC immediately after the user grants it in System Settings,
    /// but the *current process* was started before the grant and doesn't have the entitlement
    /// active at the kernel level. A fresh process launch picks it up automatically.
    private func quitAndRelaunch() {
        // Spin up a detached shell that waits for this process to exit, then
        // opens the app.  We terminate immediately after — the 0.5 s delay
        // ensures the old process (and its menu-bar icon) is fully gone before
        // the new instance starts, preventing a ghost double-icon.
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5 && open \"\(path)\""]
        task.launch()
        NSApp.terminate(nil)
    }

    private var recordButton: some View {
        Button(action: startRecording) {
            HStack {
                Image(systemName: "video.circle.fill")
                Text("Start Recording")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }

    private var stopButton: some View {
        Button(action: stopRecording) {
            HStack {
                Image(systemName: "stop.circle.fill")
                Text("Stop Recording")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.primary)
        .controlSize(.large)
    }

    private var exportProgressView: some View {
        VStack(spacing: 6) {
            ProgressView(value: appState.exportProgress)
                .progressViewStyle(.linear)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func cancelButton(label: String) -> some View {
        Button(action: cancelAction) {
            HStack {
                Image(systemName: "xmark.circle")
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var progressIndicator: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func errorView(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
            Button("×") { appState.clearError() }
                .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(6)
    }

    private func lastExportView(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail (shown when available)
            if let thumb = appState.lastExportThumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                    }
            }

            // File name + action buttons
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Show in Finder")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Copy file to clipboard")
            }
        }
        .padding(8)
        .background(Color.green.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Settings") {
                showSettings = true
            }
            .buttonStyle(.link)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .padding()
    }

    // MARK: - Actions

    private func startRecording() {
        Task { @MainActor in
            appState.clearError()
            appState.exportedFileURL = nil
            appState.lastExportThumbnail = nil
            appState.recordingState = .selectingRegion

            // Close the popover using the explicit API on AppDelegate.
            if let app = NSApp.delegate as? AppDelegate {
                app.closePopover()
            }

            await RecordingCoordinator.shared.beginSelection(appState: appState, settings: settings)
        }
    }

    private func stopRecording() {
        Task { @MainActor in
            await RecordingCoordinator.shared.stopRecording(appState: appState, settings: settings)
        }
    }

    private func cancelAction() {
        RecordingCoordinator.shared.cancel(appState: appState)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
        .environmentObject(AppSettings.shared)
}
