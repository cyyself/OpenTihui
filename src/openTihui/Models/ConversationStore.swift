//
//  ConversationStore.swift
//  openTihui
//
//  Persists the list of conversations to a JSON file and keeps it sorted by
//  most-recently-updated.
//

import Foundation
import Combine

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []

    // Chat history is private data (not configuration), so it lives under
    // Application Support and is NOT exposed in the Files app.
    private let fileURL = LocalStore.privateFileURL("conversations.json")

    init() {
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([Conversation].self, from: data)
        else { conversations = []; return }
        conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(conversations) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func upsert(_ convo: Conversation) {
        var c = convo
        c.updatedAt = Date()
        if let idx = conversations.firstIndex(where: { $0.id == c.id }) {
            conversations[idx] = c
        } else {
            conversations.append(c)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    func conversation(id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }
}
