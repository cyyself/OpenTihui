//
//  RecommendedModelsSheet.swift
//  openTihui
//
//  A curated list of known-good on-device models. One tap downloads the weights
//  plus the matching multimodal projector — replaces the old in-app Hugging Face
//  browser (arbitrary URLs are still supported via "Download from URL").
//

import SwiftUI

struct RecommendedModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(RecommendedModel.catalog) { model in
                        row(model)
                    }
                } footer: {
                    Text("Weights and the multimodal projector download together from Hugging Face (unsloth quantizations). Need a different model? Use Download from URL or drop a GGUF into the Models folder in the Files app.")
                }
            }
            .navigationTitle("Recommended Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func row(_ model: RecommendedModel) -> some View {
        let state = state(of: model)
        HStack(spacing: 12) {
            ModelBadge(name: model.name, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.body.weight(.semibold))
                Text(LocalizedStringKey(model.detail)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .downloaded:
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
            case .downloading:
                ProgressView()
            case .none:
                Button {
                    downloads.enqueue(recommended: model, store: store)
                } label: {
                    Image(systemName: "arrow.down.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private enum RowState { case none, downloading, downloaded }

    private func state(of model: RecommendedModel) -> RowState {
        if store.models.contains(where: { $0.modelPath.hasSuffix("/" + model.file) }) { return .downloaded }
        if downloads.items.contains(where: { $0.filename.hasSuffix(model.file) && $0.state == .downloading }) { return .downloading }
        return .none
    }
}
