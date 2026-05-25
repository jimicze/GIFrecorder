import AVFoundation
import AppKit
import ImageIO

/// Generates a thumbnail NSImage from an exported file for display in the popover.
/// Returns nil gracefully on any error — thumbnail is decorative, not critical.
enum ThumbnailGenerator {

    /// Maximum width of the generated thumbnail in points (matches popover width).
    static let maxWidth: CGFloat = 260

    /// Generate a thumbnail from the first frame of any exported file.
    static func generate(from url: URL, format: ExportFormat) async -> NSImage? {
        switch format {
        case .gif:
            return await thumbnailFromGIF(url: url)
        case .mp4, .mov:
            return await thumbnailFromVideo(url: url)
        }
    }

    // MARK: - Private

    private static func thumbnailFromVideo(url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxWidth * 2, height: maxWidth * 2)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            do {
                var actual = CMTime.zero
                let cg = try generator.copyCGImage(at: time, actualTime: &actual)
                return NSImage(cgImage: cg, size: Self.scaledSize(cg))
            } catch {
                return nil
            }
        }.value
    }

    private static func thumbnailFromGIF(url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return NSImage(cgImage: cg, size: Self.scaledSize(cg))
        }.value
    }

    private static func scaledSize(_ image: CGImage) -> NSSize {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(1.0, maxWidth / w)
        return NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
}
