//
//  StreamingText.swift
//  SynapLink
//
//  Smooth, easy-on-the-eyes rendering of an in-progress reply. Two ideas:
//
//   1. Decouple the visual reveal from token arrival. Tokens land in bursts;
//      a typewriter drains the buffer at a steady cadence (catching up when
//      it falls behind) so text flows in evenly instead of lurching.
//   2. Render plain text while streaming — NOT markdown. Re-parsing markdown
//      every token made bold/code/headings pop in and reflow (jarring, and
//      costly on the A13). Full markdown formatting is applied once, by
//      MessageBubble, when the finished reply is persisted.
//

import SwiftUI

struct StreamingText: View {
    let fullText: String

    @State private var typewriter = Typewriter()

    /// Live typed chunks of the smoothly-revealed prefix: code/headings/markdown
    /// render in place as they stream, not only once the reply is done.
    private var chunks: [StreamChunk] { StreamChunkParser.parse(typewriter.shown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let chunks = chunks
            ForEach(chunks) { chunk in
                StreamChunkView(chunk: chunk, showCursor: chunk.id == chunks.last?.id)
                    .equatable()
            }
        }
        .onAppear { typewriter.update(fullText) }
        .onChange(of: fullText) { typewriter.update(fullText) }
    }
}

/// Reveals text toward a moving target at a steady ~33 fps, accelerating when
/// it falls far behind so it never lags noticeably during fast bursts.
@MainActor
@Observable
final class Typewriter {
    private(set) var shown = ""

    @ObservationIgnored private var target = ""
    @ObservationIgnored private var shownCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func update(_ text: String) {
        target = text
        // A shorter target means a new turn/regeneration — restart cleanly.
        if text.count < shownCount {
            shownCount = 0
            shown = ""
        }
        if task == nil { start() }
    }

    private func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = self.target.count - self.shownCount
                if remaining > 0 {
                    // Reveal ~1/6 of the backlog per tick (min 1): smooth when
                    // close, brisk when far behind.
                    let step = max(1, remaining / 6)
                    self.shownCount += step
                    self.shown = String(self.target.prefix(self.shownCount))
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    deinit { task?.cancel() }
}
