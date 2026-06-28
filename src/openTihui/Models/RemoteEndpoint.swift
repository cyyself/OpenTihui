//
//  RemoteEndpoint.swift
//  openTihui
//
//  An OpenAI-compatible chat API endpoint (OpenAI, OpenRouter, Groq, Together,
//  DeepSeek, a self-hosted llama-server / Ollama, …). Stored locally (never
//  synced to iCloud, since it holds an API key).
//

import Foundation
import Combine

struct RemoteEndpoint: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String         // e.g. https://api.openai.com/v1
    var apiKey: String
    var modelID: String         // e.g. gpt-4o-mini
    var supportsVision: Bool = false

    /// Full chat-completions URL.
    var chatCompletionsURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/chat/completions")
    }

    /// Synthetic id used in the model picker (`remote:<uuid>`).
    var selectionTag: String { "remote:\(id.uuidString)" }
}

@MainActor
final class RemoteStore: ObservableObject {
    @Published private(set) var endpoints: [RemoteEndpoint] = []

    // Config JSON in Documents/Config (visible in the Files app). Written with
    // complete file protection since it contains API keys.
    private let fileURL = LocalStore.fileURL("remote-endpoints.json")

    init() {
        load()
    }

    func endpoint(id: UUID) -> RemoteEndpoint? { endpoints.first { $0.id == id } }
    func endpoint(tagID: String) -> RemoteEndpoint? {
        guard let uuid = UUID(uuidString: tagID) else { return nil }
        return endpoint(id: uuid)
    }

    func upsert(_ e: RemoteEndpoint) {
        if let i = endpoints.firstIndex(where: { $0.id == e.id }) { endpoints[i] = e }
        else { endpoints.append(e) }
        persist()
    }

    func delete(_ e: RemoteEndpoint) { endpoints.removeAll { $0.id == e.id }; persist() }
    func delete(at offsets: IndexSet) { endpoints.remove(atOffsets: offsets); persist() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RemoteEndpoint].self, from: data) else { return }
        endpoints = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(endpoints) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
    }
}
