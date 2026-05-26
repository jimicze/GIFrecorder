import SwiftUI
import AppKit

@main
struct GIFrecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene satisfies the SwiftUI App protocol without creating
        // any menu bar icon. AppDelegate owns the real NSStatusItem + NSPopover.
        Settings { EmptyView() }
    }
}
