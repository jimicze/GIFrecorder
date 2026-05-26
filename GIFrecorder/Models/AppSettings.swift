import Foundation
import Combine

/// UserDefaults-backed settings model. Uses UserDefaults.standard.
/// Note: never use the app's own bundle ID as a suite name — macOS forbids it
/// (suite names are for App Groups, not single-app storage).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    @Published var fps: Int {
        didSet { defaults.set(fps, forKey: Keys.fps) }
    }

    @Published var defaultFormat: ExportFormat {
        didSet { defaults.set(defaultFormat.rawValue, forKey: Keys.defaultFormat) }
    }

    @Published var defaultSaveDirectory: URL? {
        didSet {
            if let url = defaultSaveDirectory {
                defaults.set(url.path, forKey: Keys.defaultSaveDirectory)
            } else {
                defaults.removeObject(forKey: Keys.defaultSaveDirectory)
            }
        }
    }

    @Published var capturesAudio: Bool {
        didSet { defaults.set(capturesAudio, forKey: Keys.capturesAudio) }
    }

    @Published var showCountdown: Bool {
        didSet { defaults.set(showCountdown, forKey: Keys.showCountdown) }
    }

    @Published var globalHotkeyEnabled: Bool {
        didSet { defaults.set(globalHotkeyEnabled, forKey: Keys.globalHotkeyEnabled) }
    }

    @Published var autoCopyOnExport: Bool {
        didSet { defaults.set(autoCopyOnExport, forKey: Keys.autoCopyOnExport) }
    }

    @Published var showTrimUI: Bool {
        didSet { defaults.set(showTrimUI, forKey: Keys.showTrimUI) }
    }

    @Published var gifFPS: Int {
        didSet { defaults.set(gifFPS, forKey: Keys.gifFPS) }
    }

    @Published var gifMaxWidth: Int {
        didSet { defaults.set(gifMaxWidth, forKey: Keys.gifMaxWidth) }
    }

    @Published var gifMaxDurationSeconds: Int {
        didSet { defaults.set(gifMaxDurationSeconds, forKey: Keys.gifMaxDurationSeconds) }
    }

    @Published var useGifski: Bool {
        didSet { defaults.set(useGifski, forKey: Keys.useGifski) }
    }

    private enum Keys {
        static let fps = "fps"
        static let defaultFormat = "defaultFormat"
        static let defaultSaveDirectory = "defaultSaveDirectory"
        static let capturesAudio = "capturesAudio"
        static let showCountdown = "showCountdown"
        static let globalHotkeyEnabled = "globalHotkeyEnabled"
        static let autoCopyOnExport = "autoCopyOnExport"
        static let showTrimUI = "showTrimUI"
        static let gifFPS = "gifFPS"
        static let gifMaxWidth = "gifMaxWidth"
        static let gifMaxDurationSeconds = "gifMaxDurationSeconds"
        static let useGifski = "useGifski"
    }

    private init() {
        self.defaults = .standard

        self.fps = defaults.integer(forKey: Keys.fps).nonZero ?? 30
        self.capturesAudio = defaults.object(forKey: Keys.capturesAudio) as? Bool ?? true

        let storedGIFFPS = defaults.integer(forKey: Keys.gifFPS)
        self.gifFPS = storedGIFFPS > 0 ? storedGIFFPS : 15

        let storedWidth = defaults.integer(forKey: Keys.gifMaxWidth)
        self.gifMaxWidth = storedWidth > 0 ? storedWidth : 1280

        let storedDuration = defaults.integer(forKey: Keys.gifMaxDurationSeconds)
        self.gifMaxDurationSeconds = storedDuration > 0 ? storedDuration : 30
        self.useGifski = defaults.object(forKey: Keys.useGifski) as? Bool ?? true
        self.showCountdown = defaults.object(forKey: Keys.showCountdown) as? Bool ?? true
        self.globalHotkeyEnabled = defaults.object(forKey: Keys.globalHotkeyEnabled) as? Bool ?? true
        self.autoCopyOnExport = defaults.object(forKey: Keys.autoCopyOnExport) as? Bool ?? false
        self.showTrimUI = defaults.object(forKey: Keys.showTrimUI) as? Bool ?? false

        if let raw = defaults.string(forKey: Keys.defaultFormat),
           let format = ExportFormat(rawValue: raw) {
            self.defaultFormat = format
        } else {
            self.defaultFormat = .mp4
        }

        if let path = defaults.string(forKey: Keys.defaultSaveDirectory) {
            self.defaultSaveDirectory = URL(fileURLWithPath: path)
        } else {
            self.defaultSaveDirectory = nil
        }
    }

    var recordingConfig: RecordingConfig {
        RecordingConfig(fps: fps, capturesAudio: capturesAudio, exportFormat: defaultFormat)
    }

    var gifExportOptions: GIFExportOptions {
        GIFExportOptions(
            fps: gifFPS,
            maxWidth: gifMaxWidth,
            maxDurationSeconds: gifMaxDurationSeconds
        )
    }

    var gifskiExportOptions: GifskiExportOptions {
        GifskiExportOptions(
            fps: gifFPS,
            maxWidth: gifMaxWidth,
            maxDurationSeconds: gifMaxDurationSeconds
            // quality uses the default (80) — no user setting exposed yet
        )
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
