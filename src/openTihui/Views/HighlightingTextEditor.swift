//
//  HighlightingTextEditor.swift
//  openTihui
//
//  A UITextView-backed editor that highlights `$name` variable tokens with a
//  blue background, and shows the defined variables as a bar above the keyboard
//  for one-tap insertion.
//

import SwiftUI
import UIKit

struct HighlightingTextEditor: UIViewRepresentable {
    @Binding var text: String
    var variableNames: [String]

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .callout)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        tv.autocapitalizationType = .sentences
        context.coordinator.textView = tv
        tv.inputAccessoryView = context.coordinator.makeAccessory()
        tv.text = text
        context.coordinator.applyHighlight()
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.variableNames = variableNames
        context.coordinator.rebuildAccessory()
        if tv.text != text {
            tv.text = text
            context.coordinator.applyHighlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: HighlightingTextEditor
        weak var textView: UITextView?
        var variableNames: [String]
        private weak var stack: UIStackView?

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
            self.variableNames = parent.variableNames
        }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            if tv.markedTextRange == nil { applyHighlight() }   // skip during IME composition
        }

        func applyHighlight() {
            guard let tv = textView, tv.markedTextRange == nil else { return }
            let sel = tv.selectedRange
            let body = UIFont.preferredFont(forTextStyle: .callout)
            let full = NSRange(location: 0, length: (tv.text as NSString).length)
            let attr = NSMutableAttributedString(string: tv.text)
            attr.addAttribute(.font, value: body, range: full)
            attr.addAttribute(.foregroundColor, value: UIColor.label, range: full)
            for r in PromptTemplate.tokenRanges(in: tv.text) {
                attr.addAttribute(.backgroundColor, value: UIColor.systemBlue.withAlphaComponent(0.18), range: r)
                attr.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: r)
            }
            tv.attributedText = attr
            tv.selectedRange = sel
            tv.typingAttributes = [.font: body, .foregroundColor: UIColor.label]
        }

        // MARK: variable bar above the keyboard

        func makeAccessory() -> UIView {
            let bar = UIScrollView()
            bar.backgroundColor = .secondarySystemBackground
            bar.showsHorizontalScrollIndicator = false
            bar.frame = CGRect(x: 0, y: 0, width: 0, height: 46)

            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 8
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)
            self.stack = stack

            let content = bar.contentLayoutGuide
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
                stack.heightAnchor.constraint(equalTo: bar.frameLayoutGuide.heightAnchor, constant: -12),
            ])
            rebuildAccessory()
            return bar
        }

        func rebuildAccessory() {
            guard let stack = stack else { return }
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            guard !variableNames.isEmpty else {
                let label = UILabel()
                label.text = "Add variables below, then insert them here"
                label.font = .preferredFont(forTextStyle: .caption1)
                label.textColor = .secondaryLabel
                stack.addArrangedSubview(label)
                return
            }
            for name in variableNames {
                var cfg = UIButton.Configuration.gray()
                cfg.title = "$\(name)"
                cfg.baseForegroundColor = .systemBlue
                cfg.cornerStyle = .capsule
                cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                let button = UIButton(configuration: cfg)
                button.addAction(UIAction { [weak self] _ in self?.insert(name) }, for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
        }

        func insert(_ name: String) {
            guard let tv = textView else { return }
            tv.insertText("$\(name)")
            parent.text = tv.text
            applyHighlight()
        }
    }
}
