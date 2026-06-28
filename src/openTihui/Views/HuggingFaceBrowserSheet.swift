//
//  HuggingFaceBrowserSheet.swift
//  openTihui
//
//  Browse huggingface.co in-app and tap any .gguf download link to fetch it via
//  the shared DownloadManager.
//

import SwiftUI
import WebKit

struct HuggingFaceBrowserSheet: View {
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var goHome = false
    @State private var pendingURL: URL?
    @State private var toast: String?

    private let home = URL(string: "https://huggingface.co/models?library=gguf&sort=trending")!

    var body: some View {
        NavigationStack {
            HFWebView(initialURL: home, goHome: $goHome) { url in pendingURL = url }
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    if let toast {
                        Text(toast).font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule()).padding(.bottom, 60)
                            .transition(.opacity)
                    }
                }
                .navigationTitle("Hugging Face")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { goHome = true } label: { Image(systemName: "house") }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    if downloads.hasActive {
                        ToolbarItem(placement: .bottomBar) {
                            Label("\(downloads.active.count) downloading", systemImage: "arrow.down.circle").font(.caption)
                        }
                    }
                }
                .confirmationDialog("Download this model file?",
                                    isPresented: Binding(get: { pendingURL != nil }, set: { if !$0 { pendingURL = nil } }),
                                    presenting: pendingURL) { url in
                    Button("Download \(url.lastPathComponent)") {
                        downloads.enqueue(url: url, store: store)
                        flash("Added to downloads")
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { url in Text(url.lastPathComponent) }
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if toast == text { toast = nil } } }
    }
}

private struct HFWebView: UIViewRepresentable {
    let initialURL: URL
    @Binding var goHome: Bool
    var onPick: (URL) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: initialURL))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if goHome {
            wv.load(URLRequest(url: initialURL))
            DispatchQueue.main.async { goHome = false }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = navigationAction.request.url,
               u.path.contains("/resolve/"), u.path.lowercased().hasSuffix(".gguf") {
                onPick(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
