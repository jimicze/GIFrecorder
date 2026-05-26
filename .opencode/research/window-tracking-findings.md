# Window tracking and AVFoundation findings

Date: 2026-05-27

Context: macOS 13.0–15.x, arm64, Swift 5.9, ScreenCaptureKit + AVFoundation.

## Repo context

- `GIFrecorder/UI/SelectionOverlay/WindowSnapManager.swift:25-60` currently polls `CGWindowListCopyWindowInfo(...)` for snap windows.
- `GIFrecorder/Recording/RecordingEngine.swift:101-123` currently captures a full display and crops with `SCStreamConfiguration.sourceRect`.
- `GIFrecorder/Recording/RecordingEngine.swift:131-139` creates a fixed-size `AssetWriterSession`, so the current recorder pipeline assumes one width/height per segment.

## Executive summary

- **Yes, `SCStream.updateConfiguration(...)` is meant to work mid-stream** for live reconfiguration, including `sourceRect`, `width`, `height`, FPS, and related properties. Apple explicitly demos live width/height/FPS changes without restarting the stream.
- **But public evidence for `sourceRect` reliability during rapid tracking is weaker than the API contract.** Apple docs/videos say it should work; at least one Apple Developer Forums report says updates can complete successfully while frames keep the old rect/size.
- **Changing `width`/`height` mid-stream is officially supported, but frequent size churn is discouraged.** WWDC22 warns it can trigger extra memory allocation. In this repo’s current `AVAssetWriter` pipeline, dynamic size changes would also require a new writer/segment even if ScreenCaptureKit accepts them.
- **`CGWindowListCopyWindowInfo` does not appear deprecated in macOS 15.** Apple’s macOS 15 guidance deprecates capture APIs like `CGDisplayStream` / `CGWindowListCreateImage`, not the window-info API. For high-frequency window position polling, Quartz still looks like the practical choice.
- **For freeze-frame gaps in `AVMutableComposition`, do not leave an empty time range.** The most robust documented approach is to create explicit filler media (typically from the last frame via `AVAssetImageGenerator`) and insert that.
- **For mixed-dimension segments, use `AVMutableVideoComposition.renderSize` plus `AVMutableVideoCompositionLayerInstruction` transforms.** `preferredTransform` is for display/orientation metadata, not a full per-segment scale-to-fit solution.
- **`SCContentFilter(desktopIndependentWindow:)` tracks a window’s position/visibility, but not output buffer size.** Apple says the output dimension is mostly fixed and does not resize with the source window.

---

## 1) `SCStream.updateConfiguration` mid-stream

### Short answer

**Yes** — Apple documents `SCStream.updateConfiguration(...)` as a live reconfiguration API that can be called while capture is active, without stopping and restarting the stream.

### Evidence

- Apple’s ScreenCaptureKit article says: **“After the stream starts, further changes to its configuration and content filter don’t require restarting it.”** It then shows `try await stream.updateConfiguration(configuration)` and `try await stream.updateContentFilter(filter)`.
- WWDC22 (*Take ScreenCaptureKit to the next level*, session 10155) says stream properties such as output dimensions, source/destination rects, frame rate, and filter settings can be **“modified on the fly without recreating the stream.”**
- `SCStreamConfiguration.sourceRect` is a normal stream configuration property, so in principle it belongs to that live-update path.

### Code shape

```swift
streamConfig.sourceRect = newSourceRect
stream.updateConfiguration(streamConfig) { error in
    if let error {
        print("update failed: \(error)")
    }
}
```

Async form shown by Apple:

```swift
streamConfig.sourceRect = newSourceRect
try await stream.updateConfiguration(streamConfig)
```

### Caveats

- `sourceRect` only matters for **display-based capture**. Apple documents that **`sourceRect` is ignored for single-window capture**: “The system doesn’t reference this value when you capture a single window because it captures the full bounds of the window.”
- Apple publicly demos live `width`/`height`/FPS changes, but I did **not** find an Apple demo specifically showing rapid, repeated `sourceRect` tracking of a moving window.
- Apple Developer Forums thread **762133** reports a real failure mode: `updateConfiguration` completes without error, yet output sometimes keeps the **old size/old rect**.
- WWDC22 also warns that frequently changing output dimensions can cause extra allocations, and that slow surface release / queue-depth pressure leads to frame loss and glitching. That makes rapid “track window every 100 ms” reconfiguration riskier than the nominal API contract suggests.

### Practical conclusion for macOS 13/14/15

- **Supported in principle:** yes.
- **Reliability for frequent tracking updates:** **medium confidence**, not high. Public Apple docs are positive, but public field evidence shows occasional stale rect/size behavior.
- **Best practice:** debounce updates, prefer changing only `sourceRect` when possible, and keep a fallback path that stops/restarts the capture segment if the stream fails to converge after an update.

---

## 2) `SCStream.updateConfiguration` — dimension changes

### Short answer

**Yes** — Apple explicitly supports changing `width` and `height` mid-stream with `updateConfiguration(...)`.

### Evidence

- WWDC22 explicitly demos changing a stream from **4K/60** to **720p/15** via live `updateConfiguration(...)`.
- Apple’s docs say configuration changes do not require restarting the stream.

Apple’s demo shape:

```swift
streamConfiguration.width = 1280
streamConfiguration.height = 720
streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
try await stream.updateConfiguration(streamConfiguration)
```

### Caveats

- WWDC22 explicitly warns: **“frequently changing the stream’s output dimension can lead to additional memory allocation and therefore [is] not recommended.”**
- Even if ScreenCaptureKit accepts the size change, your **writer pipeline** may not. In this repo, `RecordingEngine` computes a fixed `captureWidth`/`captureHeight`, sets `streamConfig.width/height`, then creates `AssetWriterSession(url:config:videoWidth:videoHeight:)` with those exact dimensions (`RecordingEngine.swift:118-139`). That means the **current app architecture assumes fixed output dimensions for one recording segment**.

### Practical conclusion

- **ScreenCaptureKit itself:** live width/height changes are supported.
- **AVAssetWriter-based recorder architecture:** if output dimensions change, the safest production approach is usually to **start a new segment/writer** and stitch later, unless your downstream pipeline is explicitly designed for format changes.
- For a moving window whose size changes often, it is often more stable to:
  1. keep stream output dimensions fixed,
  2. accept internal scaling/padding/cropping, or
  3. split on size changes and stitch in post.

---

## 3) `CGWindowListCopyWindowInfo` deprecation

### Short answer

I found **no Apple evidence that `CGWindowListCopyWindowInfo` is deprecated in macOS 15**.

### Evidence

- Apple’s current Core Graphics docs still document `CGWindowListCopyWindowInfo(_:_:)` normally, with no deprecation marker, and describe it as returning bounds, window ID, and other window-server metadata.
- Apple’s `Quartz Window Services` docs still say this API family **“Provides information about the windows managed by the macOS window server.”**
- macOS 15 release notes and Apple DTS forum guidance call out **deprecated content-capture APIs** such as `CGDisplayStream` and `CGWindowListCreateImage`, with guidance to migrate capture/screenshot workflows to ScreenCaptureKit and `SCContentSharingPicker`.
- I found **no equivalent Apple statement** saying window enumeration/metadata should move away from `CGWindowListCopyWindowInfo`.

### Is `SCShareableContent.windows` a viable 100 ms polling replacement?

**Not as a clean drop-in replacement.**

Why:

- `SCShareableContent` is documented as a set of **capture-eligible** displays/apps/windows, not as a high-frequency polling API for live window positions.
- Retrieval is asynchronous (`getExcludingDesktopWindows(...)` / async equivalents), and Apple provides **no freshness/cadence/performance guarantee** for repeated polling.
- Apple Developer Forums include:
  - reports that `SCShareableContent.windows` can include many non-user-facing/background windows (menu bar items, wallpaper, “Focus Proxy”, etc.), and
  - at least one report of `SCShareableContent` retrieval taking **5+ seconds** in some situations.
- Apple’s WWDC story for “live updating windows” is **thumbnail streams**, not repeated metadata polling.

### Practical recommendation

- For **high-frequency window position/bounds polling** (for example, snap/tracking every ~100 ms), **Quartz remains the more practical API**.
- For **capture eligibility / picker UX / capture filters**, use **ScreenCaptureKit**.
- A hybrid approach is the most defensible:
  - `CGWindowListCopyWindowInfo` for fast-ish metadata snapshots,
  - `SCShareableContent` when you need captureable window objects / IDs / content filters.

### Important caveat

Apple does warn that generating window dictionaries can be **“relatively expensive”** and tells developers to profile. So “Quartz is better than `SCShareableContent` for 100 ms polling” does **not** mean “free.” It means “still the least-worst documented API for this specific job.”

This matches the repo’s current direction: `WindowSnapManager.snapWindows(for:)` uses `CGWindowListCopyWindowInfo(...)` directly (`WindowSnapManager.swift:29-60`).

---

## 4) `AVMutableComposition` — freeze/repeat last frame between segments

### Short answer

**Do not leave a gap.** Apple TN2447 says gaps in a video composition will “almost certainly result in black frames, or a continuation of the last frame.”

The most robust production approach is:

1. extract the last frame of segment N,
2. create explicit filler media for the gap duration,
3. insert that filler between segment N and segment N+1.

### Option evaluation

#### A) Insert segment N’s last-frame range with extended duration

**Possible in theory, weakly documented in practice.**

- `AVMutableCompositionTrack.scaleTimeRange(_:toDuration:)` only documents that it **changes the duration of a time range**.
- Apple does **not** document this as the canonical freeze-frame technique.
- In practice this is more brittle, especially if you are depending on a one-frame source range and compressed GOP boundaries.

**Verdict:** not my recommended primary approach.

#### B) `AVAssetImageGenerator` + synthesized single-frame asset

**Best documented / safest approach.**

- Apple documents `AVAssetImageGenerator` as the supported way to create images from a video asset.
- Apple’s “Creating images from a video asset” article documents exact-frame extraction by setting both requested tolerances to `.zero`.

Example:

```swift
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.appliesPreferredTrackTransform = true

let lastTime = CMTimeSubtract(asset.duration, frameDuration)
let image = try await generator.image(at: lastTime).image
```

Then encode that `CGImage` into a short filler clip of `gapDuration` and insert the filler clip into the composition.

**Verdict:** recommended.

#### C) `AVMutableVideoComposition` + `AVMutableVideoCompositionLayerInstruction`

**Not sufficient by itself.**

- Layer instructions can change **transform**, **crop**, and **opacity**.
- They do **not** choose or repeat source frames.

**Verdict:** useful for placing/scaling the filler clip, but **not** for manufacturing a freeze frame out of nothing.

#### D) Other practical option: render the still via Core Animation / custom compositor

If you already have a video-composition pipeline, you can render a still image over the gap interval using:

- `AVMutableVideoComposition.animationTool` (Core Animation), or
- a custom video compositor.

This is viable, but it is more implementation work than generating a tiny filler clip.

### Recommended answer

For a recorder/exporter pipeline, the cleanest answer is:

- **Generate the last frame with `AVAssetImageGenerator`,**
- **encode a short still-video clip matching your output canvas,**
- **insert it as an explicit segment.**

That avoids undefined-looking behavior from empty gaps and avoids overloading layer instructions for a task they were not designed to perform.

---

## 5) `AVMutableComposition` — different dimensions across segments

### Short answer

To scale segment 2 (for example `800×600`) to fit segment 1’s canvas (for example `1430×1764`), the correct API is:

- **`AVMutableVideoComposition.renderSize`** to define the output canvas, and
- **`AVMutableVideoCompositionLayerInstruction.setTransform(...)`** or `setTransformRamp(...)` to apply per-segment scale/translation.

**`preferredTransform` on `AVMutableCompositionTrack` is not the right scale-to-fit API.**

### Evidence

- Apple’s AVFoundation Programming Guide says a video composition is where you specify **render size**, **frame duration**, and per-track transforms.
- Apple documents `AVMutableVideoCompositionLayerInstruction` as the object for **transform, crop, and opacity ramps**.
- Apple documents `AVMutableCompositionTrack.preferredTransform` as **“The preferred transformation of the visual media data for display purposes.”** That is much closer to display/orientation metadata than a time-varying layout API.

### Recommended shape

```swift
let canvas = CGSize(width: 1430, height: 1764)

let videoComposition = AVMutableVideoComposition()
videoComposition.renderSize = canvas
videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: segmentStart, duration: segmentDuration)

let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)

let sourceSize = CGSize(width: 800, height: 600)
let scale = min(canvas.width / sourceSize.width,
                canvas.height / sourceSize.height)

let fittedSize = CGSize(width: sourceSize.width * scale,
                        height: sourceSize.height * scale)

let tx = (canvas.width - fittedSize.width) / 2
let ty = (canvas.height - fittedSize.height) / 2

let transform = CGAffineTransform(scaleX: scale, y: scale)
    .concatenating(CGAffineTransform(translationX: tx / scale, y: ty / scale))

layer.setTransform(transform, at: segmentStart)
instruction.layerInstructions = [layer]
videoComposition.instructions = [instruction]
```

### Caveats

- If the source track has orientation metadata, incorporate its asset-track `preferredTransform` into the final transform chain.
- If you have many sequential segments with different sizes/orientations, it is often clearer to create **one instruction per segment time range**.
- If the transform logic becomes complicated, using separate composition tracks per segment can simplify reasoning.

### Practical conclusion

- **Yes, scaling requires `AVMutableVideoComposition` layer transforms.**
- **No, setting `preferredTransform` on `AVMutableCompositionTrack` alone is not the correct full solution** for mixed-size stitched segments.

---

## 6) `SCContentFilter(desktopIndependentWindow:)` behavior on resize

### Short answer

`desktopIndependentWindow` **does track the window**, but **does not automatically resize the output buffers to match the window’s new size**.

### Evidence

- WWDC22 says single-window capture is **display- and space-independent**:
  - it continues to capture the full window when occluded,
  - when moved off-screen,
  - or when moved to another display.
- But the same session explicitly says:
  - **“The stream’s output dimension is mostly fixed and it does not resize with the source window.”**
  - ScreenCaptureKit instead performs **hardware scaling** so the captured window fits within the configured output frame.
- Apple also points developers to frame metadata such as `contentRect`, `contentScale`, and `scaleFactor` so you can interpret the resized content correctly within that fixed output frame.

### Consequence

- If your goal is **position tracking only**, `desktopIndependentWindow` is attractive because the window follows itself across displays/occlusion states.
- If your goal is **exact position + exact dynamic size + exact output-buffer dimensions**, it is **not** enough by itself.

### Practical conclusion

- **Viable for automatic window-following:** yes.
- **Viable for “output buffer automatically matches live window size”:** no.
- For exact size tracking you still need one of:
  - explicit `updateConfiguration(width/height)` calls,
  - segment restart on size changes,
  - or a fixed-canvas capture with later scaling/cropping.

---

## Overall recommendations for this app

### If you want to track a moving window with the current architecture

The current repo already uses the right building blocks for a practical hybrid approach:

- `WindowSnapManager` uses Quartz window metadata (`WindowSnapManager.swift:29-60`), which is still the better fit for high-frequency polling.
- `RecordingEngine` captures a display and crops with `sourceRect` (`RecordingEngine.swift:101-123`), which is the only path where a live `sourceRect` update makes sense.

### Best near-term strategy

1. Keep using **Quartz** for tracking window bounds/IDs.
2. Use **display capture + `sourceRect`** for motion tracking.
3. **Debounce** `updateConfiguration(...)` calls rather than firing every geometry change.
4. If the target window size changes:
   - either keep a **fixed stream/writer size** and accept scaling,
   - or start a **new segment** and stitch later.
5. Treat live width/height changes as **supported but higher risk** than live `sourceRect` changes.

### Best answer to the “full position + size tracking” question

If you need the capture output to exactly follow both **window position and window size** with stable export behavior, the most conservative production design is:

- **Quartz for tracking metadata**
- **ScreenCaptureKit display capture for pixels**
- **new segment on size changes**
- **post-stitch with `AVMutableComposition` + `AVMutableVideoComposition`**

That gives up some elegance in exchange for much more predictable behavior.

---

## Sources

### Apple docs / videos

- `SCStream.updateConfiguration(_:completionHandler:)`  
  https://docs.developer.apple.com/tutorials/data/documentation/screencapturekit/scstream/updateconfiguration(_:completionhandler:).md
- `SCStreamConfiguration.sourceRect`  
  https://docs.developer.apple.com/tutorials/data/documentation/screencapturekit/scstreamconfiguration/sourcerect.md
- `SCWindow.frame`  
  https://docs.developer.apple.com/tutorials/data/documentation/screencapturekit/scwindow/frame.md
- `SCShareableContent` / `windows` / `getExcludingDesktopWindows(...)`  
  https://docs.developer.apple.com/tutorials/data/documentation/screencapturekit/scshareablecontent.md  
  https://docs.developer.apple.com/tutorials/data/documentation/screencapturekit/scshareablecontent/windows.md  
  https://docs.developer.apple.com/tutorials/data/documentation/screencapturekit/scshareablecontent/getexcludingdesktopwindows(_:onscreenwindowsonly:completionhandler:).md
- WWDC22 session 10155, *Take ScreenCaptureKit to the next level*  
  https://developer.apple.com/videos/play/wwdc2022/10155/
- WWDC23 session 10136, *What’s new in ScreenCaptureKit*  
  https://developer.apple.com/videos/play/wwdc2023/10136/
- `CGWindowListCopyWindowInfo(_:_:)` / Quartz Window Services  
  https://docs.developer.apple.com/tutorials/data/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:).md  
  https://docs.developer.apple.com/tutorials/data/documentation/coregraphics/quartz-window-services.md
- `AVMutableCompositionTrack.insertEmptyTimeRange(_:)` / `scaleTimeRange(_:toDuration:)`  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablecompositiontrack/insertemptytimerange(_:).md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablecompositiontrack/scaletimerange(_:toduration:).md
- `AVAssetImageGenerator` / *Creating images from a video asset* / `appliesPreferredTrackTransform`  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avassetimagegenerator.md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/creating-images-from-a-video-asset.md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avassetimagegenerator/appliespreferredtracktransform.md
- `AVMutableVideoCompositionLayerInstruction` / `setTransform` / `setTransformRamp` / `renderSize` / `frameDuration` / `preferredTransform`  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablevideocompositionlayerinstruction.md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablevideocompositionlayerinstruction/settransform(_:at:).md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablevideocompositionlayerinstruction/settransformramp(fromstart:toend:timerange:).md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablevideocomposition/rendersize.md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablevideocomposition/frameduration.md  
  https://docs.developer.apple.com/tutorials/data/documentation/avfoundation/avmutablecompositiontrack/preferredtransform.md
- Apple TN2447, *Debugging AVFoundation Compositions, Video Compositions, and Audio Mixes*  
  https://developer.apple.com/library/archive/technotes/tn2447/_index.html
- Apple AVFoundation Programming Guide, *Editing*  
  https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/03_Editing.html

### Apple Developer Forums

- `updateConfiguration` sometimes keeps old rect/size  
  https://developer.apple.com/forums/thread/762133
- macOS 15 guidance about migrating deprecated content-capture APIs  
  https://developer.apple.com/forums/thread/756908
- `SCShareableContent.windows` returning many non-user-facing windows  
  https://developer.apple.com/forums/thread/756134
- `SCShareableContent` retrieval taking 5+ seconds in some cases  
  https://developer.apple.com/forums/thread/804083
