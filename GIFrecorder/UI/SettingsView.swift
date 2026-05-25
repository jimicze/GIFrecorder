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

                // Global Hotkey
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Global Keyboard Shortcut", isOn: $settings.globalHotkeyEnabled)
                    Text("⌘⇧R  —  start / stop from any app")
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
        .frame(width: 380, height: 390)
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
