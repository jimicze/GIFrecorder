import Foundation
import SwiftUI
import Combine

/// Central app state shared across all SwiftUI views.
/// Note: properties must be mutated on the main thread (use @MainActor callers or DispatchQueue.main).
final class AppState: ObservableObject {

    enum RecordingState: Equatable {
        case idle
        case selectingRegion
        case countdown(Int)
        case recording
        case stopping
        case exporting(ExportFormat)
    }

    enum ScreenRecordingPermission: Equatable {
        case unknown    // not yet checked
        case granted
        case denied
    }

    // MARK: Published State

    @Published var recordingState: RecordingState = .idle
    @Published var lastError: String?
    @Published var lastRecordingSession: RecordingSession?
    @Published var exportedFileURL: URL?
    @Published var screenRecordingPermission: ScreenRecordingPermission = .unknown
    /// 0.0–1.0 progress during `.exporting`; reset to 0 at start of each export.
    @Published var exportProgress: Double = 0

    // MARK: Derived

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    var isBusy: Bool {
        switch recordingState {
        case .idle: return false
        default: return true
        }
    }

    // MARK: Error

    func setError(_ message: String) {
        DispatchQueue.main.async { self.lastError = message }
    }

    func clearError() {
        DispatchQueue.main.async { self.lastError = nil }
    }
}
