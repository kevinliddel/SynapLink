//
//  MarkdownText.swift
//  SynapLink
//
//  Block-level markdown for a FINISHED assistant reply (the streaming path is
//  StreamingText). Both share the same typed chunks (StreamChunk) and renderer
//  (StreamChunkView): fenced ``` code as monospaced cards with a copy button,
//  #/##/### headings, inline styles (bold, italics, `code`, links).
//

import SwiftUI

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(StreamChunkParser.parse(text)) { chunk in
                StreamChunkView(chunk: chunk).equatable()
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }

    /// Markdown flattened to clean readable text — no `#`, `*`, `` ` ``, link
    /// URLs, list/quote markers, fences or rules. Used for Copy and read-aloud
    /// so neither surfaces raw syntax. Reuses the block parser, then strips
    /// inline syntax per block.
    static func plain(_ text: String) -> String {
        func stripInline(_ string: String) -> String {
            String(inline(string).characters)
        }

        var parts: [String] = []
        for chunk in StreamChunkParser.parse(text) {
            switch chunk {
            case .paragraph(_, let body), .heading(_, _, let body):
                parts.append(stripInline(body))
            case .code(_, _, let code):
                parts.append(code)
            case .quote(_, let lines):
                parts.append(lines.map { stripInline($0.text) }.joined(separator: "\n"))
            case .list(_, let items):
                parts.append(items.map { stripInline($0.text) }.joined(separator: "\n"))
            case .table(_, let data):
                let rows = [data.headers] + data.rows
                parts.append(rows.map { row in
                    row.map(stripInline).joined(separator: ", ")
                }.joined(separator: "\n"))
            case .image(_, let alt, _):
                if !alt.isEmpty { parts.append(alt) }
            case .rule, .audio:
                break
            }
        }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Code block card

struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1))
    }
}

#Preview {
    ScrollView {
        MarkdownText(text: """
        ## Quick sort

        Here is a **Swift** implementation with `generics`:

        ```swift
        func quicksort<T: Comparable>(_ array: [T]) -> [T] {
            guard array.count > 1 else { return array }
            return array
        }
        ```

        Average complexity is *O(n log n)*.
        """)
        .padding()
    }
}
