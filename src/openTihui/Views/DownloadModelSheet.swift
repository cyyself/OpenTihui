//
//  DownloadModelSheet.swift
//  openTihui
//
//  Download a GGUF (and optional mmproj) from a direct URL via the shared
//  DownloadManager. Progress + cancel live in the Models tab "Downloads" section.
//

import SwiftUI

struct DownloadModelSheet: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var modelURLString = ""
    @State private var mmprojURLString = ""

    private var modelURL: URL? {
        let s = modelURLString.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: s), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }
    private var mmprojURL: URL? {
        let s = mmprojURLString.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : URL(string: s)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    urlField("Model .gguf URL", text: $modelURLString)
                }
                Section {
                    urlField("mmproj .gguf URL (optional)", text: $mmprojURLString)
                } header: {
                    Text("Multimodal projector")
                } footer: {
                    Text("Paste direct download links to GGUF files (e.g. Hugging Face “resolve” URLs). Downloads continue in the background — track them in the Downloads section.")
                }
            }
            .navigationTitle("Download from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        if let m = modelURL { downloads.enqueue(url: m, store: store) }
                        if let p = mmprojURL { downloads.enqueue(url: p, store: store) }
                        dismiss()
                    }.disabled(modelURL == nil)
                }
            }
        }
    }

    private func urlField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .lineLimit(1...3).font(.callout)
    }
}
