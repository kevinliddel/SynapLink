//
//  StreamChunk.swift
//  SynapLink
//
//  Typed units of a reply, parsed block-by-block. The SAME parser+renderer is
//  used for the live stream (StreamingText) and the finished reply
//  (MarkdownText), so markdown renders treated AS IT STREAMS — a completed
//  **bold**, list item, table row, etc. shows formatted immediately rather
//  than as raw syntax. The last chunk is the one still being written.
//
//  Covered: headings (#..######), bold/italic/inline-code/links (inline),
//  ordered + unordered nested lists, blockquotes (incl. nested), tables,
//  fenced code (incl. mermaid, shown as a labeled code card), images.
//  `.audio` is reserved for future streamed audio output.
//
//  Rendering perf: StreamChunkView is Equatable and used via `.equatable()`,
//  so finished chunks aren't re-rendered each streamed frame.
//

import SwiftUI

struct ListItem: Equatable {
    var text: String
    var depth: Int
    var ordinal: Int?   // nil = bullet
}

struct TableData: Equatable {
    var headers: [String]
    var rows: [[String]]
}

enum StreamChunk: Identifiable, Equatable {
    case paragraph(id: Int, text: String)
    case heading(id: Int, level: Int, text: String)
    case code(id: Int, language: String?, code: String)
    case quote(id: Int, lines: [QuoteLine])
    case list(id: Int, items: [ListItem])
    case table(id: Int, data: TableData)
    case image(id: Int, alt: String, url: String)
    case rule(id: Int)   // thematic break (--- / *** / ___)
    case audio(id: Int, url: URL)   // reserved for streamed audio output

    struct QuoteLine: Equatable { var depth: Int; var text: String }

    var id: Int {
        switch self {
        case .paragraph(let id, _), .heading(let id, _, _), .code(let id, _, _),
             .quote(let id, _), .list(let id, _), .table(let id, _),
             .image(let id, _, _), .rule(let id), .audio(let id, _):
            return id
        }
    }
}

enum StreamChunkParser {

    static func parse(_ text: String) -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        var paragraph: [String] = []

        func id() -> Int { chunks.count }
        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(.paragraph(id: id(), text: joined))
            }
            paragraph = []
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code (incl. mermaid). Open fence with no close = streaming.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1  // consume closing fence (or past end)
                chunks.append(.code(id: id(), language: lang.isEmpty ? nil : lang,
                                    code: code.joined(separator: "\n")))
                continue
            }

            // Heading.
            if let h = heading(trimmed) {
                flushParagraph()
                chunks.append(.heading(id: id(), level: h.level, text: h.text))
                i += 1; continue
            }

            // Thematic break: a line of only -, *, or _ (3+).
            if isThematicBreak(trimmed) {
                flushParagraph()
                chunks.append(.rule(id: id()))
                i += 1; continue
            }

            // Table: a "| … |" row followed by a separator row.
            if isTableRow(trimmed), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(tableCells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                chunks.append(.table(id: id(), data: TableData(headers: headers, rows: rows)))
                continue
            }

            // Blockquote: contiguous lines starting with ">".
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var qlines: [StreamChunk.QuoteLine] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    qlines.append(quoteLine(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                chunks.append(.quote(id: id(), lines: qlines))
                continue
            }

            // List: contiguous ordered/unordered items (with nesting by indent).
            if listItem(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while i < lines.count, let item = listItem(lines[i]) {
                    items.append(item); i += 1
                }
                chunks.append(.list(id: id(), items: items))
                continue
            }

            // Standalone image line.
            if let img = imageOnly(trimmed) {
                flushParagraph()
                chunks.append(.image(id: id(), alt: img.alt, url: img.url))
                i += 1; continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph(); i += 1; continue
            }

            paragraph.append(line); i += 1
        }
        flushParagraph()
        return chunks
    }

    // MARK: - Line classifiers

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.dropFirst().contains("|")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return false }
        let body = t.filter { !" |:-".contains($0) }
        return body.isEmpty && t.contains("-")
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func quoteLine(_ line: String) -> StreamChunk.QuoteLine {
        var depth = 0
        var rest = Substring(line)
        while rest.first == ">" {
            depth += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return StreamChunk.QuoteLine(depth: max(1, depth), text: String(rest))
    }

    private static func listItem(_ line: String) -> ListItem? {
        let leading = line.prefix(while: { $0 == " " }).count
        let depth = leading / 4 + leading % 4 / 2   // 2- or 4-space indents
        let content = line.dropFirst(leading)

        // Unordered: -, *, +
        if let first = content.first, "-*+".contains(first),
           content.dropFirst().first == " " {
            return ListItem(text: String(content.dropFirst(2)), depth: depth, ordinal: nil)
        }
        // Ordered: 1. 2) etc.
        let digits = content.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let afterDigits = content.dropFirst(digits.count)
            if let sep = afterDigits.first, sep == "." || sep == ")",
               afterDigits.dropFirst().first == " " {
                return ListItem(text: String(afterDigits.dropFirst(2)), depth: depth,
                                ordinal: Int(digits))
            }
        }
        return nil
    }

    private static func imageOnly(_ line: String) -> (alt: String, url: String)? {
        // ![alt](url "title")  — url stops at whitespace or ).
        guard line.hasPrefix("!["), let altEnd = line.firstIndex(of: "]"),
              line.index(after: altEnd) < line.endIndex,
              line[line.index(after: altEnd)] == "(" else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd])
        let afterParen = line[line.index(altEnd, offsetBy: 2)...]
        guard let close = afterParen.firstIndex(of: ")") else { return nil }
        let inside = afterParen[..<close]
        let url = inside.split(separator: " ").first.map(String.init) ?? String(inside)
        return (alt, url)
    }
}
