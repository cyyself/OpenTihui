//
//  ShortcutsView.swift
//  openTihui
//
//  A tab of reusable "shortcuts" — each bundles a system prompt, preferred
//  model and generation config for a recurring task. Tapping one starts a
//  pre-configured chat.
//

import SwiftUI

struct ShortcutsView: View {
    @EnvironmentObject var shortcuts: ShortcutStore
    @EnvironmentObject var models: ModelStore

    var onRun: (Shortcut) -> Void

    @State private var editorTarget: Shortcut?
    @State private var exportFile: ExportFile?

    var body: some View {
        List {
            Section {
                if shortcuts.shortcuts.isEmpty {
                    Text("No shortcuts yet. Tap + to create one.").foregroundStyle(.secondary)
                }
                ForEach(shortcuts.shortcuts) { shortcut in
                    Button { onRun(shortcut) } label: { row(shortcut) }
                        .tint(.primary)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { shortcuts.delete(shortcut) } label: { Label("Delete", systemImage: "trash") }
                            Button { editorTarget = shortcut } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                        }
                        .swipeActions(edge: .leading) {
                            Button { exportShortcut(shortcut) } label: { Label("Export", systemImage: "square.and.arrow.up") }.tint(.indigo)
                        }
                        .contextMenu {
                            Button { editorTarget = shortcut } label: { Label("Edit", systemImage: "pencil") }
                            Button { exportShortcut(shortcut) } label: { Label("Export as JSON", systemImage: "square.and.arrow.up") }
                            Button(role: .destructive) { shortcuts.delete(shortcut) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } footer: {
                Text("Tap a shortcut to start a new chat pre-configured with its system prompt, model and settings — handy for translation, image recognition, summarizing, etc.")
            }
        }
        .navigationTitle("Shortcuts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editorTarget = Shortcut(name: "", icon: "sparkles", systemPrompt: "") } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editorTarget) { shortcut in
            ShortcutEditView(shortcut: shortcut) { shortcuts.upsert($0) }
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
    }

    private func exportShortcut(_ shortcut: Shortcut) {
        guard let data = shortcuts.exportData(shortcut) else { return }
        let name = shortcut.name.isEmpty ? "Shortcut" : shortcut.name
        if let url = ChatExporter.tempFile(named: name, ext: "json", data: data) {
            exportFile = ExportFile(url: url)
        }
    }

    private func row(_ shortcut: Shortcut) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: shortcut.icon).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.name.isEmpty ? "Untitled" : shortcut.name).font(.body.weight(.semibold))
                Text(subtitle(shortcut)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func subtitle(_ shortcut: Shortcut) -> String {
        let model = shortcut.modelPath.flatMap { mp in models.models.first { $0.modelPath == mp }?.name } ?? "Any model"
        return "\(model) · think \(shortcut.config.thinkingEffort.label)"
    }
}

struct ShortcutEditView: View {
    @EnvironmentObject var models: ModelStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Shortcut
    private let onSave: (Shortcut) -> Void

    init(shortcut: Shortcut, onSave: @escaping (Shortcut) -> Void) {
        _draft = State(initialValue: shortcut)
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Shortcut") {
                    TextField("Name", text: $draft.name)
                    IconPicker(icon: $draft.icon)
                }

                Section {
                    HighlightingTextEditor(text: $draft.systemPrompt,
                                           variableNames: draft.variableDefs.map { $0.name })
                        .frame(minHeight: 120)
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("Reference variables as **$name** (highlighted in blue). Tap one above the keyboard to insert it.")
                }

                Section {
                    NavigationLink {
                        VariableDefsEditor(defs: $draft.variableDefs)
                    } label: {
                        Label("Variables (\(draft.variableDefs.count))", systemImage: "curlybraces")
                    }
                } footer: {
                    Text("Define variables (e.g. language) with a list of options; users pick a value per chat.")
                }


                Section {
                    Picker("Model", selection: $draft.modelPath) {
                        Text("Any (use loaded model)").tag(String?.none)
                        ForEach(models.models) { Text($0.name).tag(String?.some($0.modelPath)) }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Pick a model to always load for this shortcut, or “Any” to use whatever is loaded.")
                }

                Section {
                    Toggle(isOn: $draft.allowInKeyboard) {
                        Label("Allow in keyboard chips", systemImage: "keyboard")
                    }
                } footer: {
                    Text("Let this shortcut be chosen as a chip in the openTihui keyboard. Turn off for vision-only shortcuts (e.g. Image Recognition).")
                }

                GenConfigEditor(config: $draft.config)
            }
            .navigationTitle(draft.name.isEmpty ? "New Shortcut" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }.disabled(!canSave)
                }
            }
        }
    }
}
