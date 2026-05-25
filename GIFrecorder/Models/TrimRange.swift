import CoreMedia

/// Represents a trimmed sub-range of a recorded video, stored as CMTime values.
struct TrimRange {
    let start: CMTime
    let end: CMTime

    /// The CMTimeRange used by AVFoundation export sessions and GIFExporter.
    var cmTimeRange: CMTimeRange {
        CMTimeRangeFromTimeToTime(start: start, end: end)
    }

    /// Build a TrimRange from 0...1 fractions of a known duration.
    static func fromFractions(startFraction: Double, endFraction: Double, duration: CMTime) -> TrimRange {
        let total = CMTimeGetSeconds(duration)
        let s = CMTime(seconds: startFraction * total, preferredTimescale: duration.timescale)
        let e = CMTime(seconds: endFraction  * total, preferredTimescale: duration.timescale)
        return TrimRange(start: s, end: e)
    }
}
