//
//  AudioAttachmentView.swift
//  SynapLink
//
//  Inline voice-note player for chat bubbles: play/pause, progress, duration.
//

import AVFoundation
import SwiftUI

struct AudioAttachmentView: View {
    let url: URL

    @State private var playback = AudioPlayback()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.toggle(url: url)
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause voice note" : "Play voice note")

            Image(systemName: "waveform")
                .font(.callout)
                .symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)

            Text(playback.timeLabel(for: url))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onDisappear { playback.stop() }
    }
}

/// Tiny AVAudioPlayer wrapper — one player per visible voice note.
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var progress: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var cachedDuration: TimeInterval?

    func toggle(url: URL) {
        if isPlaying {
            stop()
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.play()
        isPlaying = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.progress = player.currentTime
                if !player.isPlaying {
                    self.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
    }

    func timeLabel(for url: URL) -> String {
        if cachedDuration == nil {
            cachedDuration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
        }
        let shown = isPlaying ? progress : (cachedDuration ?? 0)
        let seconds = Int(shown.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
