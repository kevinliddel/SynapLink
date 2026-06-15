//
//  StreamChunkView.swift
//  SynapLink
//
//  Renders one StreamChunk. Equatable so SwiftUI skips chunks that haven't
//  changed while streaming. Shared by MarkdownText (finished reply) and
//  StreamingText (live).
//

import SwiftUI

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
                .padding(.top, 2)

        case .code(_, let language, let code):
            CodeBlockView(language: language, code: code)

        case .quote(_, let lines):
            QuoteView(lines: lines)

        case .list(_, let items):
            ListBlockView(items: items)

        case .table(_, let data):
            TableView(data: data)

        case .image(_, let alt, let url):
            MarkdownImageView(alt: alt, url: url)

        case .rule:
            Divider().padding(.vertical, 4)

        case .audio(_, let url):
            AudioAttachmentView(url: url)
        }
    }

    private var cursor: Text {
        showCursor ? Text(" ▌").foregroundColor(.secondary) : Text("")
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.bold)
        case 3: return .title3.weight(.semibold)
        case 4: return .headline
        case 5: return .subheadline.weight(.semibold)
        default: return .footnote.weight(.semibold)
        }
    }
}

// MARK: - Blockquote

private struct QuoteView: View {
    let lines: [StreamChunk.QuoteLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                    Text(MarkdownText.inline(line.text))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(line.depth - 1) * 14)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - List

private struct ListBlockView: View {
    let items: [ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(item))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(MarkdownText.inline(item.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
    }

    private func marker(_ item: ListItem) -> String {
        if let ordinal = item.ordinal { return "\(ordinal)." }
        return item.depth == 0 ? "•" : "◦"
    }
}

// MARK: - Table

private struct TableView: View {
    let data: TableData

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(data.headers.enumerated()), id: \.offset) { _, cell in
                        cellView(cell, bold: true)
                    }
                }
                .background(Color(.tertiarySystemBackground))
                ForEach(Array(data.rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            cellView(cell, bold: false)
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func cellView(_ text: String, bold: Bool) -> some View {
        Text(MarkdownText.inline(text))
            .font(.callout.weight(bold ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 60, alignment: .leading)
    }
}

// MARK: - Image

private struct MarkdownImageView: View {
    let alt: String
    let url: String

    var body: some View {
        if let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https" {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .failure:
                    placeholder
                default:
                    ProgressView().frame(maxWidth: .infinity).frame(height: 80)
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        // Offline / unreachable image — show the alt text with an icon.
        HStack(spacing: 8) {
            Image(systemName: "photo")
            Text(alt.isEmpty ? "Image" : alt).lineLimit(2)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
