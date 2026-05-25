import Foundation

/// Supported output formats for GIFrecorder.
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case mp4
    case mov
    case gif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .gif: return "GIF"
        }
    }

    var fileExtension: String { rawValue }

    var contentType: String {
        switch self {
        case .mp4: return "video/mp4"
        case .mov: return "video/quicktime"
        case .gif: return "image/gif"
        }
    }

    var supportsAudio: Bool {
        switch self {
        case .mp4, .mov: return true
        case .gif: return false
        }
    }
}
