//
//  ShareSheet.swift
//  openTihui
//
//  Wraps UIActivityViewController so exported files can be saved to Files or
//  shared. `ExportFile` makes a file URL Identifiable for `.sheet(item:)`.
//

import SwiftUI

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Full-screen "Preparing…" overlay shown while an export is being generated
/// (PDF rendering / image embedding can take a few seconds).
struct ExportingOverlay: View {
    var label: LocalizedStringKey = "Preparing export…"

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(label).font(.callout.weight(.medium))
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .transition(.opacity)
    }
}
