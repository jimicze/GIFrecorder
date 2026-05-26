# Window Tracking Recording — Design Spec
**Date:** 2026-05-27
**Status:** Approved

---

## Overview

When the "Track Window" setting is enabled and the user snaps to a window during region selection, the recording region follows that window for the entire session.

- **Position changes** (move only) → update capture region seamlessly; single segment, no stitch
- **Size changes** (resize) → pause capture, start new segment at new dimensions, stitch at export
- **Gaps** (during pause) → filled with the frozen last frame
- **Window closed/minimised** → configurable: auto-stop or pause indefinitely until reappearance

Implementation uses polling (`CGWindowListCopyWindowInfo`, 100ms interval) + `SCStream.updateConfiguration` for position changes, and stop+restart for size changes. No extra OS permissions required beyond Screen Recording.

---

## 1. Data Model & Settings

### AppSettings additions (`AppSettings.swift`)

```swift
@AppStorage("windowTrackingEnabled")
var windowTrackingEnabled: Bool = false

@AppStorage("windowTrackingOnClose")
var windowTrackingOnClose: WindowCloseAction = .pause
```

```swift
/// What to do when the tracked window closes or is minimised.
enum WindowCloseAction: String, CaseIterable {
    case stop   // auto-stop recording and proceed to export
    case pause  // freeze on last frame; resume if window reappears
}
```

### RecordingSession addition (`RecordingSession.swift`)

```swift
/// Non-nil only when window tracking is active.
var trackedWindowID: CGWindowID?
```

---

## 2. Selection Overlay Changes

### SelectionViewProtocol

Callback extended to carry the optional window ID:

```swift
protocol SelectionViewProtocol: AnyObject {
    func selectionView(_ view: SelectionView,
                       didFinishSelectingRect rect: CGRect,
                       windowID: CGWindowID?)
    func selectionViewDidCancel(_ view: SelectionView)
}
```

Freehand-drag selections always pass `windowID: nil`.
Snap-click selections pass the `SnapWindow.id` of the clicked window.

### Tracking badge (SelectionView.swift)

When `AppSettings.shared.windowTrackingEnabled == true` and a snap window is being hovered, a small pill badge — **"⊙ Track"** — is rendered in the top-right corner of the snap highlight rect. It is purely informational (confirms tracking will activate for this snap). No interaction needed; the click to confirm the region is unchanged.

### SelectionCoordinatorBridge / RecordingCoordinator

`regionSelected` signature gains `windowID: CGWindowID?`:

```swift
func regionSelected(_ rect: CGRect, windowID: CGWindowID?,
                    appState: AppState, settings: AppSettings)
```

If `settings.windowTrackingEnabled && windowID != nil`, the coordinator stores the ID in `RecordingSession.trackedWindowID` and starts `WindowTracker` after `RecordingEngine.start()` succeeds.

---

## 3. WindowTracker

New file: `GIFrecorder/Recording/WindowTracker.swift`

Single-responsibility class: polls window bounds and emits semantic events. Does not know about SCStream or AVAssetWriter.

```swift
final class WindowTracker {

    enum Event {
        case moved(newRegion: CGRect)      // position changed, size unchanged
        case resized(newRegion: CGRect)    // size changed (may also have moved)
        case disappeared                   // window gone or minimised
        case reappeared(newRegion: CGRect) // window back after disappearing
    }

    /// Delivered on the main thread.
    var onEvent: ((Event) -> Void)?

    init(windowID: CGWindowID, initialQuartzFrame: CGRect, screen: NSScreen)
    func start()  // begins 100ms repeating timer on main RunLoop
    func stop()   // invalidates timer, clears state
}
```

**Internals:**
- Stores `lastKnownFrame: CGRect` (Quartz coordinates, top-left origin)
- On each tick: call `CGWindowListCopyWindowInfo` filtered by `windowID`
- If window not found → emit `.disappeared` (once; suppress repeats while still disappeared)
- If window found after `.disappeared` → emit `.reappeared(newRegion:)`
- If size changed (width or height differs by > 2pt) → emit `.resized`
- Else if position changed (x or y differs by > 2pt) → emit `.moved`
- 2pt jitter tolerance prevents false positives during window animations
- `newRegion` is always in AppKit coordinates (bottom-left origin) — `WindowTracker` converts internally using the same `frameInScreen(_:)` logic already in `SnapWindow`

---

## 4. RecordingEngine Changes

### New state properties

```swift
private var segments: [URL] = []          // completed segment temp file URLs
private var isPaused = false
private var pendingRestartRegion: CGRect?  // set during resize restart
```

### New / changed methods

#### `pauseCapture()`
Sets `isPaused = true`. `AssetWriterSession.appendVideo` already repeats `lastPixelBuffer` for every incoming SCStream frame (the idle-frame mechanism), so the video frame freezes automatically with no further changes needed.

#### `resumeCapture(newRegion: CGRect) async`
For **position-only** changes (same dimensions):
1. Debounce: only fire after window position has been stable for ≥150ms (a second timer tick with no further change). This avoids hammering `updateConfiguration` during continuous window drag.
2. Build a new `SCStreamConfiguration` with updated `sourceRect` (same `width`/`height`)
3. Call `stream.updateConfiguration(newConfig)` — async, awaited
4. Set `isPaused = false`

No new segment is created; the existing `AssetWriterSession` continues.

> **Known reliability caveat (ADF thread 762133):** `updateConfiguration` can complete without error yet leave `sourceRect` at the old value for a frame or two. The frozen-last-frame behaviour during the debounce window masks this — by the time recording resumes, the stream has had time to settle. If `updateConfiguration` throws, fall back to `restartCapture(newRegion:)` to start a new segment.

#### `restartCapture(newRegion: CGRect) async throws`
For **size changes** (and reappearance after disappearance):
1. Call `pauseCapture()` (freeze frames during restart gap)
2. Finish current `AssetWriterSession` → append URL to `segments[]`
3. Stop current `SCStream` (`stream.stopCapture()`)
4. Compute new `captureWidth`/`captureHeight` from new region + display scale
5. Create new `AssetWriterSession` at new dimensions
6. Create new `SCStream` with new `SCContentFilter` + `SCStreamConfiguration`
7. Start new stream
8. Set `isPaused = false`

If step 6–7 fails, the error propagates via the existing `onUnexpectedStop` path. Whatever segments exist are stitched in `stop()`.

#### `stop() async throws -> URL` *(updated)*
1. Finish current segment → append to `segments[]`
2. If `segments.count == 1` → return `segments[0]` directly (no stitch needed)
3. Else → call `SegmentStitcher.stitch(segments, outputURL:)` → return stitched URL
4. Clean up all individual segment temp files

---

## 5. Segment Stitching

New file: `GIFrecorder/Recording/SegmentStitcher.swift`

```swift
enum SegmentStitcher {
    /// Stitches multiple .mov segments into a single .mov file.
    /// Gaps between segments are filled by repeating the last frame
    /// of the preceding segment.
    /// Output canvas = first segment's dimensions.
    /// Subsequent segments are scaled to fit via preferredTransform.
    static func stitch(_ segments: [URL], outputURL: URL) async throws
}
```

**Implementation using AVMutableComposition + AVMutableVideoComposition:**
1. Create `AVMutableComposition`
2. For each segment: load `AVAsset`, insert video (and audio if present) track at current time cursor
3. Between segments: fill the gap with a **freeze-frame filler clip**:
   - Extract the last frame of segment N via `AVAssetImageGenerator` (set both tolerances to `.zero` for exact frame)
   - Encode that `CGImage` into a short filler `.mov` of `gapDuration` using `AVAssetWriter` (single frame, `AVVideoCodecType.h264`, same dimensions as segment N)
   - Insert the filler clip into the composition between the two segments
4. Segments with different dimensions than the first: use `AVMutableVideoComposition` with `renderSize` = first segment's dimensions + one `AVMutableVideoCompositionInstruction` per segment time range, each with an `AVMutableVideoCompositionLayerInstruction` that applies a scale+translation transform to fit the segment's content within the canvas (letterbox/pillarbox with black fill if aspect ratio differs). **Do not use `preferredTransform` on `AVMutableCompositionTrack` for this — it is orientation metadata, not a layout API.**
5. Export via `AVAssetExportSession(.highestQuality)` to `outputURL`

**Fallback:** If stitching fails, return `segments[0]` (longest/first segment) and log an error.

---

## 6. RecordingCoordinator Integration

`RecordingCoordinator` owns the `WindowTracker` instance and wires events to `RecordingEngine`:

```swift
private var windowTracker: WindowTracker?
```

Started in `startRecording(...)` after `RecordingEngine.shared.start()` succeeds, only when `session.trackedWindowID != nil`:

```swift
windowTracker = WindowTracker(
    windowID: session.trackedWindowID!,
    initialQuartzFrame: ...,   // from SnapWindow.frame stored in session
    screen: NSScreen.main ?? NSScreen.screens[0]
)
windowTracker?.onEvent = { [weak self] event in
    Task { @MainActor in
        guard let self else { return }
        switch event {
        case .moved(let r):
            await RecordingEngine.shared.resumeCapture(newRegion: r)
        case .resized(let r):
            try? await RecordingEngine.shared.restartCapture(newRegion: r)
        case .disappeared:
            RecordingEngine.shared.pauseCapture()
            if settings.windowTrackingOnClose == .stop {
                await self.stopRecording(appState: appState, settings: settings)
            }
            // .pause: remain frozen; .reappeared will resume
        case .reappeared(let r):
            try? await RecordingEngine.shared.restartCapture(newRegion: r)
        }
    }
}
windowTracker?.start()
```

`windowTracker?.stop()` is called in `stopRecording`, `handleUnexpectedStreamStop`, and `cancel`.

`RecordingSession` also stores `initialQuartzFrame: CGRect?` (the raw Quartz-coordinate frame from `SnapWindow.frame`) so the coordinator can pass it to `WindowTracker.init` without re-querying.

---

## 7. Settings UI

`SettingsView` gains a **"Window Tracking"** section:

```
─────────────────────────────────
Window Tracking
  [toggle]  Track window position & size
  
  When window closes or minimises:
    ◉ Pause and wait for window to reappear
    ○ Stop recording automatically
  (shown only when toggle is ON)
─────────────────────────────────
```

No changes to `MenuBarView`.

---

## 8. Error Handling

| Scenario | Behaviour |
|---|---|
| `WindowTracker` starts before engine | Not possible — tracker starts only after `RecordingEngine.start()` succeeds |
| `restartCapture` stream setup fails | Error via `onUnexpectedStop`; existing segments stitched in `stop()` |
| Stitching fails | Falls back to returning `segments[0]`; warning logged via `flog` |
| Window reappears at a different size than it disappeared | `restartCapture` handles it (same as resize) |
| Tracking on, user draws freehand (no snap) | `windowID == nil` → tracker not started; recording proceeds as normal |
| Display disconnected during tracking | Existing `SCStream` error propagation handles this; tracker fires `.disappeared` |

---

## 9. Files Changed / Created

| File | Change |
|---|---|
| `GIFrecorder/Models/AppSettings.swift` | Add `windowTrackingEnabled`, `windowTrackingOnClose`, `WindowCloseAction` |
| `GIFrecorder/Models/RecordingSession.swift` | Add `trackedWindowID: CGWindowID?`, `initialQuartzFrame: CGRect?` |
| `GIFrecorder/UI/SelectionOverlay/SelectionView.swift` | Pass `windowID` in callback; draw "⊙ Track" badge when tracking enabled |
| `GIFrecorder/UI/SelectionOverlay/SelectionWindow.swift` | Update delegate protocol signature |
| `GIFrecorder/App/RecordingCoordinator.swift` | Accept `windowID`; own `WindowTracker`; wire events to engine |
| `GIFrecorder/Recording/RecordingEngine.swift` | Add `segments[]`, `pauseCapture`, `resumeCapture`, `restartCapture`; update `stop()` |
| `GIFrecorder/Recording/WindowTracker.swift` | **New** — polling, event emission |
| `GIFrecorder/Recording/SegmentStitcher.swift` | **New** — AVMutableComposition stitching |
| `GIFrecorder/UI/SettingsView.swift` | Add Window Tracking section |
| `project.yml` | Register `WindowTracker.swift`, `SegmentStitcher.swift` |

---

## 10. Out of Scope

- Multi-display window tracking (window dragged to a second monitor) — B-07 dependency
- Audio continuity across segment boundaries (AAC encoder state reset on restart)
- Variable-canvas output (each segment at its own resolution) — incompatible with H.264 MP4
- Tracking windows that belong to the GIFrecorder app itself
