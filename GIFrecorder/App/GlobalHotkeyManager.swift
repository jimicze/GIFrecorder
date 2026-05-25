import Carbon
import AppKit

/// Registers a system-wide hotkey (⌘⇧R) using the Carbon Event Manager.
///
/// Carbon's `RegisterEventHotKey` does NOT require Accessibility permission —
/// it registers at the OS level so the shortcut works from any app.
/// The hotkey is: Command + Shift + R  (⌘⇧R)
final class GlobalHotkeyManager {

    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Fired on the main thread each time ⌘⇧R is pressed.
    var onToggle: (() -> Void)?

    private init() {}

    deinit { unregister() }

    // MARK: - Public

    /// Registers the ⌘⇧R hotkey. Safe to call multiple times — no-ops if already registered.
    func register() {
        guard hotKeyRef == nil else { return }

        // Install a Carbon keyboard event handler for kEventHotKeyPressed.
        // The closure is non-capturing (uses userData to reach self), so it is
        // implicitly @convention(c) — compatible with InstallEventHandler.
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
                DispatchQueue.main.async { manager.onToggle?() }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )

        // Register ⌘⇧R (Command + Shift + R).
        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = fourCharCode("GFRC")
        hotkeyID.id = 1

        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | shiftKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    /// Unregisters the hotkey and removes the Carbon event handler.
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    // MARK: - Private

    private func fourCharCode(_ s: String) -> FourCharCode {
        var result: FourCharCode = 0
        for scalar in s.unicodeScalars.prefix(4) {
            result = (result << 8) + FourCharCode(scalar.value)
        }
        return result
    }
}
