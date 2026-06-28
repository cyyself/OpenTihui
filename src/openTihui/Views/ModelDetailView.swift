//
//  ModelDetailView.swift
//  openTihui
//
//  Model details: projector (mmproj) selection and "set as default".
//  Loading is done from the chat, not here.
//

import SwiftUI

struct ModelDetailView: View {
    let model: ManagedModel

    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var settings: AppSettings

    @State private var selectedProjector: String?
    @State private var displayName: String

    init(model: ManagedModel) {
        self.model = model
        _selectedProjector = State(initialValue: model.mmprojPath)
        _displayName = State(initialValue: model.name)
    }

    /// Name derived from the file name, used as the placeholder / reset value.
    private var defaultName: String {
        URL(fileURLWithPath: model.modelPath).deletingPathExtension().lastPathComponent
    }

    private func commitName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? defaultName : trimmed
        guard target != model.name else { return }      // no change
        store.setName(trimmed.isEmpty ? nil : trimmed, for: model)
        if trimmed.isEmpty { displayName = defaultName }
    }

    /// Available projectors, with the model's own-folder ones listed first (they
    /// are the default pairing).
    private var projectors: [URL] {
        let dir = URL(fileURLWithPath: model.modelPath).deletingLastPathComponent().path
        return store.availableProjectors().sorted { a, b in
            let aSame = a.deletingLastPathComponent().path == dir
            let bSame = b.deletingLastPathComponent().path == dir
            if aSame != bSame { return aSame }
            return a.lastPathComponent.localizedCompare(b.lastPathComponent) == .orderedAscending
        }
    }
    private var isDefault: Bool { settings.defaultModelPath == model.modelPath }

    /// True when a projector lives next to this model's `.gguf` (i.e. it's a
    /// multimodal model) or one is currently paired — so we only show the picker
    /// for models that actually relate to a projector, not every text model.
    private var relatesToProjector: Bool {
        let dir = URL(fileURLWithPath: model.modelPath).deletingLastPathComponent().path
        return model.hasMultimodal || projectors.contains { $0.deletingLastPathComponent().path == dir }
    }

    /// A label that disambiguates projectors that share a filename: `./name` when
    /// the projector sits next to the model's `.gguf`, otherwise a path relative
    /// to the Models folder (or the full path if it lives elsewhere).
    private func projectorLabel(_ url: URL) -> String {
        let modelDir = URL(fileURLWithPath: model.modelPath).deletingLastPathComponent().path
        if url.deletingLastPathComponent().path == modelDir {
            return "./\(url.lastPathComponent)"
        }
        return ModelStore.appRelativePath(url.path)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Name")
                    Spacer()
                    TextField(defaultName, text: $displayName)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .onSubmit { commitName() }
                }
                LabeledContent("Size", value: model.fileSizeText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Path").font(.caption).foregroundStyle(.secondary)
                    Text(model.displayPath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)   // wrap, never truncate
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Renaming changes the display name only — the file on disk (\(model.fileName)) is unchanged.")
            }

            Section {
                Button {
                    settings.defaultModelPath = isDefault ? nil : model.modelPath
                } label: {
                    HStack {
                        Label(isDefault ? "Default Model" : "Set as Default", systemImage: isDefault ? "star.fill" : "star")
                        Spacer()
                        if isDefault { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }
                }
            } footer: {
                Text("The default model is used for new chats (loaded when you start typing).")
            }

            // Offer the projector picker whenever any projector was found — so the
            // user can pick among same-named files (shown with disambiguating
            // paths) or choose None to disable a projector that isn't usable here.
            if relatesToProjector {
                Section {
                    Picker(selection: $selectedProjector) {
                        Text("None (text only)").tag(String?.none)
                        ForEach(projectors, id: \.path) { url in
                            Text(projectorLabel(url))
                                .fixedSize(horizontal: false, vertical: true)   // wrap, never truncate
                                .tag(String?.some(url.path))
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: selectedProjector) { _, newValue in
                        store.setProjector(newValue, for: model)
                    }
                } header: {
                    Text("Multimodal projector (mmproj)")
                } footer: {
                    Text("Choose which projector to pair with this model, or None to run it text-only. `./` means the file sits next to the model; other paths are relative to the Models folder. Applied the next time the model loads.")
                }
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { commitName() }
    }
}
