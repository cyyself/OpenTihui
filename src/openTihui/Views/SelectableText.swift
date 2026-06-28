//
//  SelectableText.swift
//  openTihui
//
//  A selectable, Markdown-rendering text view for chat bubbles (UITextView under
//  the hood). Supports drag-to-select with the system menu (Copy, Look Up,
//  Translate, Share…) plus a custom **Speak** item.
//

import SwiftUI
import UIKit

struct SelectableText: UIViewRepresentable {
    let text: String
    var textColor: UIColor
    var onSpeak: (String) -> Void   // speaks the selection, or the whole message

    func makeUIView(context: Context) -> SpeakableTextView {
        let tv = SpeakableTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: SpeakableTextView, context: Context) {
        tv.fullText = text
        tv.onSpeak = onSpeak
        tv.attributedText = MarkdownAttributed.make(text, color: textColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SpeakableTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, fit.width), height: fit.height)
    }
}

/// UITextView that injects a "Speak" item into the text-selection menu.
final class SpeakableTextView: UITextView {
    var fullText = ""
    var onSpeak: ((String) -> Void)?

    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let speak = UIAction(title: String(localized: "Speak"), image: UIImage(systemName: "speaker.wave.2.fill")) { [weak self] _ in
            guard let self else { return }
            let selected = self.selectedTextRange.flatMap { self.text(in: $0) } ?? ""
            self.onSpeak?(selected.isEmpty ? self.fullText : selected)
        }
        var actions = suggestedActions
        actions.append(UIMenu(title: "", options: .displayInline, children: [speak]))
        return UIMenu(children: actions)
    }
}

/// Builds an attributed string from Markdown (inline styles + headings, bullet /
/// numbered lists, fenced code blocks) for display in a UITextView.
enum MarkdownAttributed {
    static func make(_ text: String, color: UIColor) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let out = NSMutableAttributedString()
        var codeLines: [String] = []
        var inCode = false

        func appendLine(_ s: NSAttributedString) {
            out.append(s)
            out.append(NSAttributedString(string: "\n", attributes: [.font: body, .foregroundColor: color]))
        }

        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode { appendLine(codeBlock(codeLines.joined(separator: "\n"), base: body, color: color)); codeLines = []; inCode = false }
                else { inCode = true }
                continue
            }
            if inCode { codeLines.append(raw); continue }

            if let (level, htext) = heading(trimmed) {
                appendLine(inline(htext, base: headingFont(level), color: color))
            } else if let item = bullet(trimmed) {
                let line = NSMutableAttributedString(string: "•  ", attributes: [.font: body, .foregroundColor: color])
                line.append(inline(item, base: body, color: color))
                appendLine(line)
            } else if let (n, item) = ordered(trimmed) {
                let line = NSMutableAttributedString(string: "\(n).  ", attributes: [.font: body, .foregroundColor: color])
                line.append(inline(item, base: body, color: color))
                appendLine(line)
            } else {
                appendLine(inline(raw, base: body, color: color))
            }
        }
        if inCode { appendLine(codeBlock(codeLines.joined(separator: "\n"), base: body, color: color)) }
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    // MARK: inline

    private static func inline(_ s: String, base: UIFont, color: UIColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        guard let astr = try? AttributedString(markdown: s, options: opts) else {
            return NSAttributedString(string: s, attributes: [.font: base, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in astr.runs {
            let piece = String(astr[run.range].characters)
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = UIFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
                } else {
                    var traits = base.fontDescriptor.symbolicTraits
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if let d = base.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: d, size: base.pointSize) }
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let link = run.link { attrs[.link] = link }
            result.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return result
    }

    private static func codeBlock(_ s: String, base: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
            .foregroundColor: color,
            .backgroundColor: UIColor.label.withAlphaComponent(0.06),
        ])
    }

    // MARK: block helpers

    private static func headingFont(_ level: Int) -> UIFont {
        let style: UIFont.TextStyle = level == 1 ? .title2 : (level == 2 ? .title3 : .headline)
        let f = UIFont.preferredFont(forTextStyle: style)
        return UIFont(descriptor: f.fontDescriptor.withSymbolicTraits(.traitBold) ?? f.fontDescriptor, size: f.pointSize)
    }

    private static func heading(_ s: String) -> (Int, String)? {
        var level = 0, idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 { level += 1; idx = s.index(after: idx) }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        return (level, String(s[s.index(after: idx)...]))
    }

    private static func bullet(_ s: String) -> String? {
        for m in ["- ", "* ", "+ "] where s.hasPrefix(m) { return String(s.dropFirst(m.count)) }
        return nil
    }

    private static func ordered(_ s: String) -> (Int, String)? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let rest = s[s.index(s.startIndex, offsetBy: digits.count)...]
        guard rest.hasPrefix(". ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }
}
