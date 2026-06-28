//
//  Conversation.swift
//  openTihui
//
//  Persistable chat history. Conversations are stored as JSON in Application
//  Support; attachments are referenced by their on-disk file path.
//

import Foundation

struct StoredAttachment: Codable, Hashable {
    var kind: String          // "image" | "audio"
    var path: String
}

struct StoredMessage: Codable, Identifiable {
    var id: UUID = UUID()
    var role: String          // "user" | "assistant"
    var text: String
    var attachments: [StoredAttachment] = []
    var stats: String?
}

struct Conversation: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelID: UUID?
    var modelName: String?
    var systemPrompt: String?    // per-conversation override (e.g. from a shortcut)
    var modelPath: String?       // local model this conversation was started with
    var remoteEndpointId: String?// remote API endpoint (uuid string); nil = local
    var config: GenConfig?       // per-conversation context + sampling + reasoning
    var icon: String?            // SF Symbol (nil = default)
    var variables: [String: String]?       // chosen values for $vars
    var variableDefs: [PromptVariableDef]? // per-chat variable definitions (name + options)
    var variableScope: String?             // namespace for remembered values (shortcut name)
    var messages: [StoredMessage] = []
}

// MARK: - Conversions between runtime ChatMessage and persisted form

extension ChatMessage {
    init(stored: StoredMessage) {
        let atts: [Attachment] = stored.attachments.compactMap { sa in
            guard FileManager.default.fileExists(atPath: sa.path) else { return nil }
            return Attachment(kind: sa.kind == "audio" ? .audio : .image,
                              url: URL(fileURLWithPath: sa.path))
        }
        self.init(role: stored.role == "assistant" ? .assistant : .user,
                  text: stored.text,
                  attachments: atts,
                  stats: stored.stats,
                  isStreaming: false,
                  failed: false)
    }

    var stored: StoredMessage {
        StoredMessage(role: role == .assistant ? "assistant" : "user",
                      text: text,
                      attachments: attachments.map {
                          StoredAttachment(kind: $0.kind == .audio ? "audio" : "image", path: $0.url.path)
                      },
                      stats: stats)
    }
}
