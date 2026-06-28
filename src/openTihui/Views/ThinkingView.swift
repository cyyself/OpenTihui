//
//  ThinkingView.swift
//  openTihui
//
//  Renders a model's <think>…</think> reasoning as a tidy collapsible block
//  instead of dumping raw tags into the chat.
//

import SwiftUI

struct ReasoningSplit {
    var thinking: String?   // reasoning content, nil if the message has none
    var answer: String      // the visible answer
    var isThinking: Bool    // currently inside an unclosed <think> block
}

/// Split an assistant message into its reasoning and answer parts.
func splitReasoning(_ text: String) -> ReasoningSplit {
    guard let open = text.range(of: "<think>") else {
        return ReasoningSplit(thinking: nil, answer: text, isThinking: false)
    }
    let before = String(text[..<open.lowerBound])
    let after = text[open.upperBound...]
    if let close = after.range(of: "</think>") {
        let think = String(after[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = (before + String(after[close.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
        return ReasoningSplit(thinking: think, answer: answer, isThinking: false)
    }
    return ReasoningSplit(thinking: String(after).trimmingCharacters(in: .whitespacesAndNewlines),
                          answer: before.trimmingCharacters(in: .whitespacesAndNewlines),
                          isThinking: true)
}

struct ThinkingView: View {
    let text: String
    let isLive: Bool          // model is still actively reasoning
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(isLive ? "Thinking…" : "Thoughts")
                    if isLive { ProgressView().controlSize(.mini) }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text.isEmpty ? "…" : text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 2)
                    }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { expanded = isLive }
        .onChange(of: isLive) { _, live in
            withAnimation(.easeInOut(duration: 0.15)) { expanded = live }
        }
    }
}
