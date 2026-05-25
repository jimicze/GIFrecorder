// GIFrecorder/UI/TrimSheet.swift
import AppKit
import AVFoundation
import AVKit
import SwiftUI

// MARK: - Range Slider

/// Two-handle slider for selecting a sub-range of a 0...1 normalised value space.
struct RangeSlider: View {
    @Binding var startFraction: Double   // 0...1
    @Binding var endFraction: Double     // 0...1
    var minSpan: Double = 0.05

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(0, (endFraction - startFraction) * w), height: 4)
                    .offset(x: startFraction * w)

                thumb
                    .offset(x: startFraction * w - 10)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let raw = drag.location.x / w
                                startFraction = max(0, min(endFraction - minSpan, raw))
                            }
                    )

                thumb
                    .offset(x: endFraction * w - 10)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let raw = drag.location.x / w
                                endFraction = max(startFraction + minSpan, min(1, raw))
                            }
                    )
            }
        }
        .frame(height: 20)
    }

    private var thumb: some View {
        Circle()
            .fill(Color.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: 20, height: 20)
    }
}

// MARK: - AVPlayerView wrapper

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - TrimSheet

struct TrimSheet: View {
    let sourceURL: URL
    let onConfirm: (TrimRange?) -> Void   // nil = no trim
    let onCancel: () -> Void

    @State private var player: AVPlayer
    @State private var duration: Double = 1.0
    @State private var startFraction: Double = 0.0
    @State private var endFraction: Double = 1.0
    @State private var isLoaded = false

    init(sourceURL: URL, onConfirm: @escaping (TrimRange?) -> Void, onCancel: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._player = State(initialValue: AVPlayer(url: sourceURL))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Trim Recording")
                .font(.headline)

            PlayerView(player: player)
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .cornerRadius(8)

            if isLoaded {
                VStack(spacing: 4) {
                    RangeSlider(startFraction: $startFraction, endFraction: $endFraction)
                        .padding(.horizontal, 4)
                        .onChange(of: startFraction) { _ in seekToStart() }

                    HStack {
                        Text(formatSeconds(startFraction * duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatSeconds((endFraction - startFraction) * duration) + " selected")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Text(formatSeconds(endFraction * duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button("No Trim") { onConfirm(nil) }
                    .buttonStyle(.bordered)
                Button("Export Trimmed") {
                    guard isLoaded else { return }
                    let totalTime = CMTime(seconds: duration, preferredTimescale: 600)
                    let trim = TrimRange.fromFractions(
                        startFraction: startFraction,
                        endFraction: endFraction,
                        duration: totalTime
                    )
                    onConfirm(trim)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isLoaded)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await loadDuration() }
        .onDisappear { player.pause() }
    }

    private func loadDuration() async {
        let asset = AVURLAsset(url: sourceURL)
        guard let dur = try? await asset.load(.duration) else { return }
        let seconds = CMTimeGetSeconds(dur)
        guard seconds > 0 else { return }
        await MainActor.run {
            duration = seconds
            isLoaded = true
            player.seek(to: .zero)
            player.play()
        }
    }

    private func seekToStart() {
        let seekTime = CMTime(seconds: startFraction * duration, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }

    private func formatSeconds(_ s: Double) -> String {
        let total = max(0, Int(s))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
