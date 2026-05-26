import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                // FPS
                Picker("Frame Rate", selection: $settings.fps) {
                    Text("15 FPS").tag(15)
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                .pickerStyle(.segmented)

                // Default Format
                Picker("Default Format", selection: $settings.defaultFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                // Audio Toggle
                Toggle("Capture Desktop Audio", isOn: $settings.capturesAudio)

                // Countdown Toggle
                Toggle("Show 3-Second Countdown", isOn: $settings.showCountdown)

                // Auto-copy Toggle
                Toggle("Copy to Clipboard After Export", isOn: $settings.autoCopyOnExport)

                // Trim UI Toggle
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Trim UI After Recording", isOn: $settings.showTrimUI)
                    Text("Opens a trim sheet to clip the start and end before exporting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Global Hotkey
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Global Keyboard Shortcut", isOn: $settings.globalHotkeyEnabled)
                    Text("⌘⇧R  —  start / stop from any app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Dock Icon
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Dock Icon", isOn: $settings.showDockIcon)
                    Text("Also appears in the ⌘Tab app switcher.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Save Location
                HStack {
                    Text("Save to")
                    Spacer()
                    Button(saveDirLabel) {
                        chooseSaveDirectory()
                    }
                    .buttonStyle(.link)
                }

                // GIF Quality
                Section("GIF Export") {
                    Picker("Frame Rate", selection: $settings.gifFPS) {
                        Text("5 FPS").tag(5)
                        Text("10 FPS").tag(10)
                        Text("15 FPS (default)").tag(15)
                        Text("24 FPS").tag(24)
                        Text("30 FPS").tag(30)
                    }

                    Picker("Max Width", selection: $settings.gifMaxWidth) {
                        Text("480 px").tag(480)
                        Text("720 px").tag(720)
                        Text("1080 px").tag(1080)
                        Text("1280 px (default)").tag(1280)
                        Text("Original").tag(9999)
                    }

                    Stepper(
                        "Max Duration: \(settings.gifMaxDurationSeconds)s",
                        value: $settings.gifMaxDurationSeconds,
                        in: 5...60,
                        step: 5
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Use gifski (higher quality, slower)", isOn: $settings.useGifski)
                        Text("Falls back to the built-in encoder if gifski fails.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 380, height: 590)
    }

    private var saveDirLabel: String {
        settings.defaultSaveDirectory?.lastPathComponent ?? "Desktop"
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultSaveDirectory = url
        }
    }
}
