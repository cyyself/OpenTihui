//
//  ChatSettingsView.swift
//  openTihui
//
//  Per-chat configuration: icon, model, system prompt, context, sampling, reasoning.
//

import SwiftUI

struct ChatSettingsView: View {
    @EnvironmentObject var chat: ChatViewModel
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var remotes: RemoteStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var config = GenConfig.default
    @State private var systemPrompt = ""
    @State private var icon = "bubble.left.fill"
    @State private var modelPath: String?
    @State private var name = ""
    @State private var variableDefs: [PromptVariableDef] = []
    @State private var loaded = false

    private var defaultModelName: String {
        settings.defaultModelPath.flatMap { mp in models.models.first { $0.modelPath == mp }?.name } ?? "Auto"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Chat name", text: $name)
                    IconPicker(icon: $icon)
                }

                Section {
                    Picker("Model", selection: $modelPath) {
                        Text("Default (\(defaultModelName))").tag(String?.none)
                        if !models.models.isEmpty {
                            Section("On-device") {
                                ForEach(models.models) { Text($0.name).tag(String?.some($0.modelPath)) }
                            }
                        }
                        if !remotes.endpoints.isEmpty {
                            Section("API") {
                                ForEach(remotes.endpoints) { Label($0.name, systemImage: "cloud").tag(String?.some($0.selectionTag)) }
                            }
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Use an on-device model or a remote API endpoint. On-device models reload when changed; API endpoints connect on send.")
                }

                Section {
                    HighlightingTextEditor(text: $systemPrompt, variableNames: variableDefs.map { $0.name })
                        .frame(minHeight: 100)
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("Leave empty to use the global default. Reference variables as **$name** (blue) — tap one above the keyboard to insert it.")
                }

                Section {
                    NavigationLink {
                        VariableDefsEditor(defs: $variableDefs)
                    } label: {
                        Label("Variables (\(variableDefs.count))", systemImage: "curlybraces")
                    }
                } footer: {
                    Text("Define variables with options; pick a value per chat from the bar above the composer.")
                }

                GenConfigEditor(config: $config)
            }
            .navigationTitle("Chat Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        let defs = variableDefs.filter { !$0.name.isEmpty }
                        Task { await chat.applyChatSettings(config, systemPrompt: sys.isEmpty ? nil : sys, icon: icon,
                                                            modelPath: modelPath, name: name, variableDefs: defs) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                config = chat.config
                systemPrompt = chat.systemPromptOverride ?? ""
                icon = chat.icon
                modelPath = chat.currentRemoteEndpoint?.selectionTag ?? chat.pinnedModelPath
                name = chat.currentTitle
                variableDefs = chat.variableDefs
                loaded = true
            }
        }
    }
}
