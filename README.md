# GIFrecorder

A native macOS screen recorder for Apple Silicon. Capture any screen region or auto-snap to an app window, record desktop audio, and export as **MP4**, **MOV**, or **GIF**.

---

## Requirements

| Requirement | Version |
|-------------|---------|
| macOS | 13.0 Ventura or later |
| Xcode | 15.0 or later (16.x recommended) |
| Architecture | Apple Silicon (arm64) only |

---

## Quick Run (30 seconds)

```bash
# 1. Clone / enter the project
cd /path/to/GIFrecorder

# 2. Generate the Xcode project (only needed once, or after editing project.yml)
xcodegen generate

# 3. Build — DerivedData lands in ./DerivedData inside the project folder
xcodebuild -project GIFrecorder.xcodeproj \
           -scheme GIFrecorder \
           -configuration Debug \
           -arch arm64 \
           -derivedDataPath DerivedData \
           build

# 4. Open the built app directly from the project folder
open DerivedData/Build/Products/Debug/GIFrecorder.app
```

Or open in Xcode and press **⌘R** (Xcode will also use `./DerivedData` thanks to workspace settings):

```bash
open GIFrecorder.xcodeproj
```

---

## First-Launch: Grant Screen Recording Permission

> ⚠️ **The app will not work without this permission.** macOS blocks screen capture by default.

1. Launch the app (it appears in your **menu bar** — look for the `⊙` circle icon)
2. Click the menu bar icon → click **Start Recording**
3. macOS will show a prompt: **"GIFrecorder would like to record this computer's screen"**
4. Click **Open System Settings**
5. In **System Settings → Privacy & Security → Screen Recording**, toggle **GIFrecorder** to ON
6. Quit and relaunch the app (`⌘Q` or Quit from the popover)

After granting permission, the app works without restarting the system.

---

## How to Use

### 1. Start a recording

Click the **`⊙`** icon in the menu bar → click **Start Recording**.

The screen dims and a crosshair cursor appears.

### 2. Select a region

You have two ways:

| Mode | How |
|------|-----|
| **Draw** | Click and drag anywhere on screen to draw a selection rectangle |
| **Window Snap** | Hover over any open window — it highlights in blue. Click to select its exact bounds. |

Press **Escape** to cancel.

### 3. Countdown & recording

- A **3-second countdown** appears (can be disabled in Settings)
- The menu bar icon **pulses red** while recording
- Recording starts automatically after countdown

### 4. Stop recording

Click the **`⊙`** menu bar icon → click **Stop Recording**

### 5. Save

A save panel appears. Choose:
- **Format**: `.mp4`, `.mov`, or `.gif`
- **Location**: anywhere on your Mac (default: Desktop)
- **Filename**: pre-filled as `recording-YYYY-MM-DD-HH-mm-ss`

Click **Save**. A "Show in Finder" button appears in the popover when done.

---

## Settings

Click the menu bar icon → **Settings**

| Setting | Options | Default |
|---------|---------|---------|
| Frame Rate | 15 / 30 / 60 FPS | 30 FPS |
| Default Format | MP4 / MOV / GIF | MP4 |
| Capture Desktop Audio | On / Off | On |
| Show 3-Second Countdown | On / Off | On |
| Save Location | Any folder | Desktop |

---

## Output Formats

| Format | Audio | Notes |
|--------|-------|-------|
| **MP4** | ✅ AAC | H.264, best compatibility |
| **MOV** | ✅ AAC | H.264, Apple ecosystem |
| **GIF** | ❌ | 15fps, max 1280px wide, max 30 seconds |

> **GIF note**: GIF export is capped at 30 seconds. Large regions are automatically scaled down to 1280px wide for file size. Export may take a few seconds.

---

## Build Commands

```bash
# Debug build  →  app at DerivedData/Build/Products/Debug/GIFrecorder.app
xcodebuild -project GIFrecorder.xcodeproj -scheme GIFrecorder \
           -configuration Debug -arch arm64 -derivedDataPath DerivedData build

# Release build  →  app at DerivedData/Build/Products/Release/GIFrecorder.app
xcodebuild -project GIFrecorder.xcodeproj -scheme GIFrecorder \
           -configuration Release -arch arm64 -derivedDataPath DerivedData build

# Run all tests
xcodebuild test -project GIFrecorder.xcodeproj -scheme GIFrecorder \
           -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData

# Clean  (wipes ./DerivedData)
xcodebuild clean -project GIFrecorder.xcodeproj -scheme GIFrecorder \
           -derivedDataPath DerivedData

# Regenerate Xcode project (after editing project.yml)
xcodegen generate
```

### Open the built app

```bash
# Debug
open DerivedData/Build/Products/Debug/GIFrecorder.app

# Release
open DerivedData/Build/Products/Release/GIFrecorder.app
```

---

## Debugging

### The permission problem — read this first

GIFrecorder requires **Screen Recording permission** before SCStream can start.
macOS enforces a restart of the app after permission is granted.
This breaks a naive "launch from Xcode → grant permission → debug" workflow because the
restart kills the Xcode debugger session.

**The correct one-time setup:**

```bash
# 1. Build the Debug app
xcodebuild -project GIFrecorder.xcodeproj -scheme GIFrecorder \
           -configuration Debug -arch arm64 -derivedDataPath DerivedData build

# 2. Launch it standalone (NOT from Xcode) to trigger the permission prompt
open build/Debug/GIFrecorder.app

# 3. Click the ⊙ menu bar icon → click Start Recording
#    macOS shows a dialog: "GIFrecorder would like to record this computer's screen"
#    Go to System Settings → Privacy & Security → Screen Recording → toggle GIFrecorder ON

# 4. Quit the app (right-click the ⊙ icon → Quit, or press ⌘Q)
```

Permission is now **persisted** to the bundle identity of the Debug build.
Every subsequent Xcode launch (⌘R) or standalone launch of that same binary
will have permission already granted — no restart needed.

---

### Option A — Live debugging in Xcode (recommended)

After the one-time setup above:

1. Open `GIFrecorder.xcodeproj` in Xcode (or run `open GIFrecorder.xcodeproj`)
2. Press **⌘R** — Xcode builds Debug and launches with the debugger attached
3. All `os_log` output and `print()` appears in the **Debug Console** (⌘⇧Y)
4. Set breakpoints anywhere in source; execution pauses in-line with variable inspection
5. Click the `⊙` menu bar icon to interact with the app normally

> **If permission was lost** (e.g. after a clean build that changed the code signature):
> repeat the one-time setup — quit Xcode, run standalone once, grant permission, quit, then ⌘R again.

---

### Option B — Attach LLDB to a running process

When the app is already running and you want to attach without restarting it:

1. **In Xcode:** `Debug → Attach to Process → GIFrecorder`
   Full debugger — breakpoints, variable inspection, pause/continue.

2. **Via command line:**

```bash
# Find PID (optional — lldb -n uses the process name directly)
pgrep -x GIFrecorder

# Attach by name
xcrun lldb -n GIFrecorder
```

Useful `lldb` commands once attached:

```
(lldb) b RecordingEngine.swift:52          # breakpoint at start()
(lldb) b RecordingCoordinator.swift:128    # breakpoint at startRecording()
(lldb) c                                   # continue
(lldb) bt                                  # backtrace on pause/crash
(lldb) po error                            # print an object
(lldb) p captureWidth                      # print a value
```

---

### Option C — Stream live logs (works regardless of how the app was launched)

The app uses `os.Logger` throughout. Use `log stream` to tail live output from
any terminal — even after the app is restarted independently of Xcode:

```bash
# All GIFrecorder logs (info + above)
log stream --level info --predicate 'subsystem == "com.gifrecorder.app"'

# Include debug-level messages (more verbose)
log stream --level debug --predicate 'subsystem == "com.gifrecorder.app"'

# Add ScreenCaptureKit internals (stream setup failures, permission errors, frame delivery)
log stream --level debug \
  --predicate 'subsystem == "com.gifrecorder.app" \
               OR subsystem == "com.apple.ScreenCaptureKit"'

# Add AVFoundation / VideoToolbox (H.264 encoder, AVAssetWriter pipeline)
log stream --level debug \
  --predicate 'subsystem == "com.gifrecorder.app" \
               OR subsystem == "com.apple.ScreenCaptureKit" \
               OR subsystem BEGINSWITH "com.apple.avfoundation" \
               OR subsystem == "com.apple.videotoolbox"'
```

Logged events include: permission check result, region dimensions, computed H.264 pixel size,
stream start/stop, export format + filename, and all error paths.

> **Note:** `log stream` only captures `os_log` / `Logger` output — not bare `print()`.
> The app's key events all use `Logger`; internal framework logs come from their own subsystems.

---

### Option D — Environment variables for extra diagnostics

```bash
# All os_log output printed to stderr even if the log level would suppress it
env OS_ACTIVITY_MODE=debug \
    open build/Debug/GIFrecorder.app

# AVFoundation writer / encoder trace messages
env AVFOUNDATION_DIAGNOSTICS=1 \
    open build/Debug/GIFrecorder.app
```

To set these permanently in Xcode:
**Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**

| Variable | Value | Effect |
|----------|-------|--------|
| `OS_ACTIVITY_MODE` | `debug` | All `os_log` messages go to stderr / Xcode console |
| `CFLOG_FORCE_STDERR` | `1` | Core Foundation logs go to stderr |
| `AVFOUNDATION_DIAGNOSTICS` | `1` | AVFoundation writer/encoder trace |
| `MallocStackLogging` | `1` | Records malloc stacks for memory debugging (slow) |

---

### Symbolicate a crash report

```bash
# Locate crash logs
ls ~/Library/Logs/DiagnosticReports/ | grep GIFrecorder

# Symbolicate using the dSYM from the Debug build
xcrun atos -arch arm64 \
           -o DerivedData/Build/Products/Debug/GIFrecorder.app/Contents/MacOS/GIFrecorder \
           -l <load_address> <crash_address>
```

---

## Project Structure

```
GIFrecorder/
├── DerivedData/               Build output (git-ignored, lives here in the project folder)
├── GIFrecorder.xcodeproj/     Xcode project (generated by xcodegen)
├── project.yml                xcodegen source of truth — edit this, not .xcodeproj
├── GIFrecorder/
│   ├── App/                   Entry point, AppDelegate, AppState, RecordingCoordinator
│   ├── UI/                    MenuBarView, SettingsView, CountdownOverlay
│   │   └── SelectionOverlay/  Screen overlay (draw + window snap)
│   ├── Recording/             SCStream engine, AVAssetWriter session
│   ├── Export/                MP4 / MOV / GIF exporters
│   ├── Models/                ExportFormat, AppSettings, RecordingSession
│   └── Resources/             Info.plist, entitlements, assets
├── GIFrecorderTests/          Unit tests (13 tests)
├── PRD.md                     Product requirements
├── TASKS.md                   Implementation tracker
└── AGENTS.md                  AI agent instructions
```

---

## Troubleshooting

### App icon doesn't appear in menu bar
- Check that **Screen Recording permission** is granted (see above)
- Check that the app hasn't been blocked by Gatekeeper: `System Settings → Privacy & Security → Open Anyway`

### "Stream setup failed" error
- Most common cause: Screen Recording permission not granted or not yet active after granting
- Fix: Quit and relaunch the app after granting permission in System Settings

### GIF export is slow
- Normal for large regions or long recordings
- GIF is CPU-intensive; a 10-second 1280×720 GIF takes ~3–8 seconds
- Reduce the selected region size or recording duration

### Recording appears frozen / blank
- ScreenCaptureKit requires active screen content; a fully static screen may produce fewer frames
- This is handled internally — the recording will still have correct duration

### Build fails: "No such module 'ScreenCaptureKit'"
- Ensure you're building for `arm64` only and targeting macOS 13.0+
- Run `xcodegen generate` to regenerate the project if build settings look wrong

### "xcodegen: command not found"
```bash
brew install xcodegen
```

---

## Known Limitations (MVP)

- Single display only (primary display)
- No global hotkey for start/stop
- No recording trim before export
- GIF quality is lower than gifski (uses macOS built-in ImageIO encoder)
- No microphone audio (desktop/system audio only)
- No App Store distribution (requires screen recording entitlement outside sandbox)
