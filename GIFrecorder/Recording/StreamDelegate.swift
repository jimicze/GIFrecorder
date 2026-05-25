import ScreenCaptureKit
import AVFoundation

/// Implements SCStreamOutput and SCStreamDelegate.
/// Routes CMSampleBuffers to AssetWriterSession and propagates stream errors to RecordingEngine.
final class StreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let session: AssetWriterSession

    /// Called (on an arbitrary thread) when the stream stops due to an unexpected error.
    /// Set by RecordingEngine before starting capture; cleared after stopping cleanly.
    var onUnexpectedStop: ((Error) -> Void)?

    init(session: AssetWriterSession) {
        self.session = session
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch outputType {
        case .screen:
            session.appendVideo(sampleBuffer)
        case .audio:
            session.appendAudio(sampleBuffer)
        case .microphone:
            // SCStreamOutputType.microphone (macOS 15.0+): we don't capture microphone audio.
            break
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Propagate to RecordingEngine so AppState can be updated and the UI unblocked.
        onUnexpectedStop?(error)
    }
}
