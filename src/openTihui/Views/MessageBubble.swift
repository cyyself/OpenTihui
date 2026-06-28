//
//  MessageBubble.swift
//  openTihui
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !message.attachments.isEmpty {
                    attachmentRow
                }
                contentView
                if let stats = message.stats {
                    Text(stats)
                        .font(.caption2)
                        .foregroundStyle(isUser ? Color.white.opacity(0.7) : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if !isUser { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isUser {
            if !message.text.isEmpty {
                SelectableText(text: message.text, textColor: .white) { Speaker.shared.speak($0) }
            }
        } else {
            let split = splitReasoning(message.text)
            if split.thinking != nil || split.isThinking {
                ThinkingView(text: split.thinking ?? "", isLive: message.isStreaming && split.isThinking)
            }
            if !split.answer.isEmpty {
                SelectableText(text: split.answer, textColor: .label) { Speaker.shared.speak($0) }
            } else if message.isStreaming && split.thinking == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var attachmentRow: some View {
        let images = message.attachments.filter { $0.kind == .image }
        let audios = message.attachments.filter { $0.kind == .audio }
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(images) { att in
                            if let img = UIImage(contentsOfFile: att.url.path) {
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
            ForEach(audios) { _ in
                Label("Audio clip", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
            }
        }
    }

    private var bubbleBackground: Color {
        if message.failed { return Color.red.opacity(0.18) }
        return isUser ? Color.accentColor : Color(.secondarySystemBackground)
    }
}
