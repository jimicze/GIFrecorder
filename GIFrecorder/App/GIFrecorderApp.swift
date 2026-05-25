import SwiftUI
import AppKit

@main
struct GIFrecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // MenuBarExtra is the macOS 13+ native scene for status-bar apps.
        // Using it (even with windowStyle .automatic and an EmptyView) avoids
        // the SwiftUI Settings{} scene, which internally calls
        // UserDefaults(suiteName: bundleIdentifier) and logs a spurious warning.
        // All real UI and status-item management is still handled by AppDelegate;
        // this declaration just satisfies the SwiftUI App protocol requirement.
        MenuBarExtra("GIFrecorder", systemImage: "record.circle") {
            // AppDelegate owns the real NSStatusItem and NSPopover.
            // This MenuBarExtra body is never shown — AppDelegate's status item
            // takes visual precedence. EmptyView keeps SwiftUI happy.
            EmptyView()
        }
    }
}
