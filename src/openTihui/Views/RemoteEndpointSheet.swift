//
//  RemoteEndpointSheet.swift
//  openTihui
//
//  Add / edit an OpenAI-compatible API endpoint.
//

import SwiftUI

struct RemoteEndpointSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RemoteEndpoint
    private let onSave: (RemoteEndpoint) -> Void

    init(endpoint: RemoteEndpoint, onSave: @escaping (RemoteEndpoint) -> Void) {
        _draft = State(initialValue: endpoint)
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.modelID.trimmingCharacters(in: .whitespaces).isEmpty &&
        draft.chatCompletionsURL != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoint") {
                    TextField("Name", text: $draft.name)
                    TextField("Base URL (e.g. https://api.openai.com/v1)", text: $draft.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API Key", text: $draft.apiKey)
                    TextField("Model ID (e.g. gpt-4o-mini)", text: $draft.modelID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Toggle("Vision (image) support", isOn: $draft.supportsVision)
                } footer: {
                    Text("Works with any OpenAI-compatible API — OpenAI, OpenRouter, Groq, Together, DeepSeek, or a self-hosted llama-server / Ollama. The key is stored only on this device.")
                }

                Section {
                    presetButton("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini")
                    presetButton("OpenRouter", "https://openrouter.ai/api/v1", "openai/gpt-4o-mini")
                    presetButton("Groq", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile")
                    presetButton("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat")
                    presetButton("Local llama-server", "http://127.0.0.1:8080/v1", "local")
                } header: {
                    Text("Quick fill")
                }
            }
            .navigationTitle(draft.name.isEmpty ? "New Endpoint" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }.disabled(!canSave)
                }
            }
        }
    }

    private func presetButton(_ name: String, _ url: String, _ model: String) -> some View {
        Button {
            if draft.name.isEmpty { draft.name = name }
            draft.baseURL = url
            if draft.modelID.isEmpty || draft.modelID == "local" { draft.modelID = model }
        } label: {
            HStack { Text(name); Spacer(); Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .tint(.primary)
    }
}
