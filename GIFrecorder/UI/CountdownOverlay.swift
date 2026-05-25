import AppKit
import SwiftUI

// MARK: - State model (drives animation safely through SwiftUI ObservableObject)

final class CountdownState: ObservableObject {
    @Published var value: Int
    init(_ value: Int) { self.value = value }
}

// MARK: - Window

/// Full-screen semi-transparent overlay shown during the pre-recording countdown.
final class CountdownWindow: NSWindow {

    private var countdownValue: Int
    /// Called every second with the new countdown value (e.g. 3 → 2 → 1).
    private let onTick: ((Int) -> Void)?
    /// Called after the countdown reaches 0 and the overlay hides.
    private let onFinished: () -> Void
    private var timer: Timer?
    private let countdownState: CountdownState

    init(countdownFrom: Int, onTick: ((Int) -> Void)? = nil, onFinished: @escaping () -> Void) {
        self.countdownValue = countdownFrom
        self.onTick = onTick
        self.onFinished = onFinished

        // Prefer main screen; fall back gracefully — never crash if no screen.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let state = CountdownState(countdownFrom)
        self.countdownState = state

        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        self.isOpaque = false
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.ignoresMouseEvents = true

        self.contentView = NSHostingView(rootView: CountdownView(state: state))
    }

    // CountdownWindow ignores mouse events and handles no keyboard input —
    // it must never become key (doing so steals focus from other windows
    // and triggers a "canBecomeKeyWindow returned NO" warning on borderless windows).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Lifecycle

    func startCountdown() {
        // orderFront: show above other windows without stealing key focus.
        // makeKeyAndOrderFront would warn because canBecomeKey is false.
        orderFront(nil)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countdownValue -= 1

            if self.countdownValue <= 0 {
                self.timer?.invalidate()
                self.timer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.orderOut(nil)
                    self?.onFinished()
                }
            } else {
                // Update state — SwiftUI animates the number change via .contentTransition
                self.countdownState.value = self.countdownValue
                self.onTick?(self.countdownValue)
            }
        }
    }

    /// Immediately stops the countdown and hides the window without calling `onFinished`.
    func cancelCountdown() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }
}

// MARK: - SwiftUI view

struct CountdownView: View {
    @ObservedObject var state: CountdownState

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 16) {
                Text("\(state.value)")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: state.value)

                Text("Recording starts...")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
    }
}
