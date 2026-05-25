import Foundation
import UniformTypeIdentifiers

extension ExportFormat {
    var utType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .gif: return .gif
        }
    }
}
