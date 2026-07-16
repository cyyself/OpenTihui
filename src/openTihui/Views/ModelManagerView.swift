//
//  ModelManagerView.swift
//  openTihui
//

import SwiftUI
import UniformTypeIdentifiers

/// Presentation state for the model-management sheets. Owned by SettingsView,
/// which attaches the actual `.sheet` modifiers to the Form's *root* — inside
/// the lazy Form/List, rows get recycled on scroll/updates, and a sheet
/// presented from a recycled row is torn down (the "sheet randomly closes" bug).
final class ModelSheets: ObservableObject {
    @Published var showImporter = false
    @Published var showDownloader = false
    @Published var showRecommended = false
    @Published var editingEndpoint: RemoteEndpoint?
}

struct ModelManagerView: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var chat: ChatViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var remotes: RemoteStore
    @EnvironmentObject var downloads: DownloadManager

    @EnvironmentObject var sheets: ModelSheets

    /// Rendered as a group of `Section`s so it can sit at the top of the
    /// Settings `Form` (no `List`/toolbar of its own). Sheets are presented by
    /// SettingsView from the Form's root — never from these (lazy) sections.
    var body: some View {
        Group {
            if !downloads.items.isEmpty {
                downloadsSection
            }
            if store.models.isEmpty && !downloads.items.contains(where: { $0.filename.contains("Qwen3.5") }) {
                starterSection
            }
            localModelsSection
            endpointsSection
                .onAppear { store.reloadInBackground() }
        }
    }

    private var downloadsSection: some View {
        Section {
            ForEach(downloads.items) { downloadRow($0) }
        } header: {
            HStack {
                Text("Downloads")
                Spacer()
                if downloads.items.contains(where: { $0.state != .downloading }) {
                    Button("Clear") { downloads.clearFinished() }.font(.caption)
                }
            }
        }
    }

    private var starterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("No models yet", systemImage: "sparkles").font(.headline)
                Text("Try the recommended **Qwen3.5 0.8B** — a small, fast, vision-capable model that runs well on-device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    downloads.enqueueRecommended(store: store)
                } label: {
                    Label("Download recommended model", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Or use the **+** button to pick a recommended model, download from a URL, import from the Files app, or add an API endpoint.")
        }
    }

    private var localModelsSection: some View {
        Section {
            if store.models.isEmpty {
                Text("Downloaded and imported models appear here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.models) { model in
                modelRow(model)
            }
            .onDelete(perform: deleteModels)
        } header: {
            HStack {
                Text("Available Local Models")
                Spacer()
                Menu {
                    Button { sheets.showRecommended = true } label: { Label("Recommended Models", systemImage: "sparkles") }
                    Button { sheets.showDownloader = true } label: { Label("Download from URL", systemImage: "arrow.down.circle") }
                    Button { sheets.showImporter = true } label: { Label("Import from Files", systemImage: "folder") }
                    Button { sheets.editingEndpoint = RemoteEndpoint(name: "", baseURL: "https://api.openai.com/v1", apiKey: "", modelID: "") } label: { Label("Add API Endpoint", systemImage: "cloud") }
                } label: { Label("Add", systemImage: "plus.circle") }
            }
        } footer: {
            Text("Model weights live in the app's **Models** folder, visible under “On My iPhone/iPad ▸ openTihui” in the Files app. Drop `.gguf` files there (and `mmproj-*.gguf` projectors for vision models) and pull to refresh.")
        }
    }

    private var endpointsSection: some View {
        Section {
            if remotes.endpoints.isEmpty {
                Text("Add an OpenAI-compatible API endpoint to use a cloud model.").foregroundStyle(.secondary)
            }
            ForEach(remotes.endpoints) { ep in
                Button { sheets.editingEndpoint = ep } label: {
                    HStack {
                        Image(systemName: "cloud").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.name).foregroundStyle(.primary)
                            Text(ep.modelID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if ep.supportsVision { Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .swipeActions { Button(role: .destructive) { remotes.delete(ep) } label: { Label("Delete", systemImage: "trash") } }
            }
        } header: {
            Text("Online API Endpoints")
        } footer: {
            Text("OpenAI-compatible cloud or LAN models. Keys are stored only on this device.")
        }
    }

    private func modelRow(_ model: ManagedModel) -> some View {
        let isDefault = settings.defaultModelPath == model.modelPath
        return NavigationLink {
            ModelDetailView(model: model)
        } label: {
            HStack(spacing: 12) {
                ModelBadge(name: model.name, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.body).lineLimit(2)
                    if model.folderLabel != "Models" {
                        Text(model.displayPath).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        Text(model.fileSizeText).font(.caption).foregroundStyle(.secondary)
                        if model.hasMultimodal {
                            HStack(spacing: 3) {
                                Image(systemName: "photo")
                                Text("Multimodal")
                            }
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                        if model.isBuiltIn {
                            Text("test").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if isDefault {
                    Label("Default", systemImage: "star.fill")
                        .labelStyle(.iconOnly).foregroundStyle(.yellow)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                settings.defaultModelPath = isDefault ? nil : model.modelPath
            } label: { Label("Default", systemImage: "star") }.tint(.yellow)
        }
    }

    @ViewBuilder
    private func downloadRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch item.state {
                case .downloading:
                    Button { downloads.cancel(item) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            switch item.state {
            case .downloading:
                ProgressView(value: item.progress)
                Text(item.bytesText).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            case .finished:
                Text("Finished").font(.caption2).foregroundStyle(.secondary)
            case .failed(let msg):
                Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func deleteModels(at offsets: IndexSet) {
        for i in offsets { store.delete(store.models[i]) }
    }
}

/// Two-step importer: choose a GGUF model and an optional mmproj projector.
struct ImportModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onImport: (URL, URL?) -> Void

    @State private var modelURL: URL?
    @State private var mmprojURL: URL?
    @State private var picking: Picking?

    private enum Picking { case model, mmproj }

    private var ggufType: [UTType] { [UTType(filenameExtension: "gguf") ?? .data, .data] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model file (required)") {
                    fileRow(url: modelURL, placeholder: "Choose .gguf model") { picking = .model }
                }
                Section("Multimodal projector (optional)") {
                    fileRow(url: mmprojURL, placeholder: "Choose mmproj .gguf") { picking = .mmproj }
                    if mmprojURL != nil {
                        Button("Remove projector", role: .destructive) { mmprojURL = nil }
                    }
                }
                Section {
                    Text("The projector (mmproj) enables image / audio input for vision-language models such as Qwen-VL.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        if let modelURL { onImport(modelURL, mmprojURL); dismiss() }
                    }.disabled(modelURL == nil)
                }
            }
            .fileImporter(isPresented: Binding(get: { picking != nil },
                                               set: { if !$0 { picking = nil } }),
                          allowedContentTypes: ggufType) { result in
                if case .success(let url) = result {
                    if picking == .model { modelURL = url } else { mmprojURL = url }
                }
                picking = nil
            }
        }
    }

    private func fileRow(url: URL?, placeholder: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: url == nil ? "doc.badge.plus" : "doc.fill")
                Text(url?.lastPathComponent ?? placeholder)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(url == nil ? Color.secondary : Color.primary)
                Spacer()
            }
        }
    }
}
