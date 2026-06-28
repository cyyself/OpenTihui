//
//  MarkdownText.swift
//  openTihui
//
//  Lightweight, dependency-free Markdown renderer for chat messages. Handles the
//  common things models emit — bold/italic/`code`/links (inline), headings,
//  bullet & numbered lists, and fenced code blocks — and degrades to plain text
//  for anything it doesn't recognise. Safe to re-render every streaming token.
//

import SwiftUI

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    // MARK: Blocks

    private enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case bullets([String])
        case ordered([String])
        case code(String)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            inline(s).font(headingFont(level)).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let s):
            Text(s)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level { case 1: return .title2; case 2: return .title3; default: return .headline }
    }

    /// Inline Markdown (bold/italic/code/links/strikethrough), preserving newlines.
    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)) {
            return Text(attr)
        }
        return Text(s)
    }

    // MARK: Parser

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() }
        }
        func flushBullets() { if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets.removeAll() } }
        func flushOrdered() { if !ordered.isEmpty { blocks.append(.ordered(ordered)); ordered.removeAll() } }
        func flushLists() { flushBullets(); flushOrdered() }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n"))); codeLines.removeAll(); inCode = false
                } else {
                    flushParagraph(); flushLists(); inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); flushLists(); continue }

            if let h = heading(trimmed) {
                flushParagraph(); flushLists(); blocks.append(.heading(h.0, h.1)); continue
            }
            if let item = bulletItem(trimmed) {
                flushParagraph(); flushOrdered(); bullets.append(item); continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph(); flushBullets(); ordered.append(item); continue
            }
            flushLists()
            paragraph.append(line)
        }
        if inCode { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph(); flushLists()
        return blocks
    }

    private static func heading(_ s: String) -> (Int, String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 { level += 1; idx = s.index(after: idx) }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[s.index(after: idx)...]))
    }

    private static func bulletItem(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) { return String(s.dropFirst(marker.count)) }
        return nil
    }

    private static func orderedItem(_ s: String) -> String? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = s[s.index(s.startIndex, offsetBy: digits.count)...]
        guard rest.hasPrefix(". ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
