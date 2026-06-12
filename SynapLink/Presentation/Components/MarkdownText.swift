//
//  MarkdownText.swift
//  SynapLink
//
//  Block-level markdown for assistant replies: fenced ``` code blocks render
//  as monospaced cards with a copy button, #/##/### headings get heading
//  fonts, and everything else keeps inline markdown (bold, italics, `code`,
//  links). An unterminated fence is treated as an open code block so
//  streamed code renders live while the model is still typing it.
//

import SwiftUI

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.parse(text)) { block in
                switch block.kind {
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .heading(let level, let content):
                    Text(Self.inline(content))
                        .font(headingFont(level))
                case .paragraph(let content):
                    Text(Self.inline(content))
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(MarkdownBlock(id: blocks.count, kind: .paragraph(joined)))
            }
            paragraph = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(MarkdownBlock(id: blocks.count,
                                        kind: .code(language: codeLanguage,
                                                    codeLines.joined(separator: "\n"))))
                    codeLines = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }

            if inCode {
                codeLines.append(String(line))
            } else if let heading = headingLine(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(id: blocks.count,
                                    kind: .heading(level: heading.level, heading.text)))
            } else {
                paragraph.append(String(line))
            }
        }

        // Streaming: an open fence renders as a live code block.
        if inCode {
            blocks.append(MarkdownBlock(id: blocks.count,
                                kind: .code(language: codeLanguage,
                                            codeLines.joined(separator: "\n"))))
        }
        flushParagraph()
        return blocks
    }

    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

/// One rendered block of a markdown message.
struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(String)
        case heading(level: Int, String)
        case code(language: String?, String)
    }

    let id: Int
    let kind: Kind
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
            let pivot = array[array.count / 2]
            return quicksort(array.filter { $0 < pivot })
                 + array.filter { $0 == pivot }
                 + quicksort(array.filter { $0 > pivot })
        }
        ```

        Average complexity is *O(n log n)*.
        """)
        .padding()
    }
}
