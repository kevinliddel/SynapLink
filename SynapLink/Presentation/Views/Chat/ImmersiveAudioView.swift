//
//  ImmersiveAudioView.swift
//  SynapLink
//
//  Full-screen voice-note capture: dark immersive backdrop, a live level
//  ring around the mic, elapsed time, cancel / send. Recording starts on
//  appear; "send" hands the WAV bytes back to the chat.
//

import SwiftUI

struct ImmersiveAudioView: View {
    /// Called with the recorded WAV on send; nil on cancel.
    let sampleRate: Int32
    let onFinish: (Data?) -> Void

    @State private var recorder = VoiceRecorder()
    @State private var permissionDenied = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(white: 0.16), .black],
                           center: .center, startRadius: 40, endRadius: 500)
                .ignoresSafeArea()

            VStack(spacing: 36) {
                Spacer()

                if permissionDenied {
                    permissionPrompt
                } else {
                    levelRing
                    VStack(spacing: 6) {
                        Text(recorder.isRecording ? "Listening…" : "Starting…")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                        Text(timeString)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Spacer()
                controls
            }
            .padding(.bottom, 48)
        }
        .task { await startRecording() }
    }

    // MARK: - Pieces

    private var levelRing: some View {
        ZStack {
            // Outer ring breathes with the input level.
            Circle()
                .fill(Color.green.opacity(0.18))
                .frame(width: 180, height: 180)
                .scaleEffect(1 + recorder.level * 0.45)
                .animation(.easeOut(duration: 0.12), value: recorder.level)
            Circle()
                .fill(Color.green.gradient)
                .frame(width: 120, height: 120)
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: recorder.isRecording)
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash.circle")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.7))
            Text("Microphone access is off")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
            Text("Enable it in Settings → SynapLink to send voice messages. Audio is processed on-device only.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var controls: some View {
        HStack(spacing: 60) {
            Button {
                recorder.cancel()
                onFinish(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("Cancel")

            if !permissionDenied {
                Button {
                    onFinish(recorder.stop())
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 72, height: 72)
                        .background(.white, in: Circle())
                }
                .disabled(!recorder.isRecording)
                .accessibilityLabel("Send voice message")
            }
        }
    }

    private var timeString: String {
        let seconds = Int(recorder.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func startRecording() async {
        guard await VoiceRecorder.requestPermission() else {
            permissionDenied = true
            return
        }
        do {
            try recorder.start(sampleRate: sampleRate)
        } catch {
            permissionDenied = true
        }
    }
}

#Preview {
    ImmersiveAudioView(sampleRate: 16000) { _ in }
}
