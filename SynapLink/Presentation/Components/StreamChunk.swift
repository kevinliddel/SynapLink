//
//  StreamChunk.swift
//  SynapLink
//
//  Typed units of a streamed reply. A reply is parsed into an ordered list of
//  chunks; the LAST chunk is the one still being written. The text model emits
//  `.paragraph` / `.heading` / `.code`; `.image` and `.audio` are reserved for
//  future producers (streaming TTS, image output) so one renderer handles
//  every stream — and markdown renders *as it streams*, not only at the end.
//
//  Rendering perf: StreamChunkView is Equatable and used via `.equatable()`,
//  so SwiftUI skips re-rendering chunks that haven't changed. During streaming
//  only the open (last) chunk is rebuilt each frame; finished chunks above it
//  format exactly once.
//

import SwiftUI

enum StreamChunk: Identifiable, Equatable {
    case paragraph(id: Int, text: String)
    case heading(id: Int, level: Int, text: String)
    case code(id: Int, language: String?, code: String)
    case image(id: Int, url: URL)   // reserved for streamed image output
    case audio(id: Int, url: URL)   // reserved for streamed audio output

    var id: Int {
        switch self {
        case .paragraph(let id, _), .heading(let id, _, _), .code(let id, _, _),
             .image(let id, _), .audio(let id, _):
            return id
        }
    }
}

/// Splits reply text into typed chunks. Pure text scanning — no AttributedString
/// work (that happens lazily in StreamChunkView for the chunks actually shown).
/// An unterminated final ``` fence is treated as an open code block so code
/// streams inside its card rather than as raw text that pops into one later.
enum StreamChunkParser {

    static func parse(_ text: String) -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(.paragraph(id: chunks.count, text: joined))
            }
            paragraph = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    chunks.append(.code(id: chunks.count, language: codeLanguage,
                                        code: codeLines.joined(separator: "\n")))
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
                chunks.append(.heading(id: chunks.count, level: heading.level, text: heading.text))
            } else {
                paragraph.append(String(line))
            }
        }

        if inCode {
            chunks.append(.code(id: chunks.count, language: codeLanguage,
                                code: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return chunks
    }

    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }
}

/// Renders one chunk. Equatable so SwiftUI skips unchanged chunks while streaming.
struct StreamChunkView: View, Equatable {
    let chunk: StreamChunk
    var showCursor = false

    static func == (lhs: StreamChunkView, rhs: StreamChunkView) -> Bool {
        lhs.chunk == rhs.chunk && lhs.showCursor == rhs.showCursor
    }

    var body: some View {
        switch chunk {
        case .paragraph(_, let text):
            (Text(MarkdownText.inline(text)) + cursor)
                .textSelection(.enabled)
        case .heading(_, let level, let text):
            (Text(MarkdownText.inline(text)).font(Self.headingFont(level)) + cursor)
                .textSelection(.enabled)
        case .code(_, let language, let code):
            CodeBlockView(language: language, code: code)
        case .image(_, let url):
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .audio(_, let url):
            AudioAttachmentView(url: url)
        }
    }

    /// Neutral caret — no accent tint (intentionally low-key while streaming).
    private var cursor: Text {
        showCursor ? Text(" ▌").foregroundColor(.secondary) : Text("")
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}
