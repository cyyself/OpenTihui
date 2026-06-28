//
//  LogView.swift
//  openTihui
//
//  Shows the captured llama.cpp / ggml log output (model load, backend init,
//  context sizing, generation stats…) so users can inspect or share it when
//  reporting an issue.
//

import SwiftUI

struct LogView: View {
    @State private var text = ""
    @State private var autoRefresh = true
    @State private var exportFile: ExportFile?

    // Refresh the snapshot periodically while the view is open.
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? String(localized: "No logs yet. Load a model or run a generation to populate the log.") : text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: text) { _, _ in
                if autoRefresh { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $autoRefresh) { Label("Auto-refresh", systemImage: "arrow.clockwise") }
                    Button { refresh() } label: { Label("Refresh now", systemImage: "arrow.clockwise.circle") }
                    Divider()
                    Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { share() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) { LlamaBridge.clearLog(); text = "" } label: { Label("Clear", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .onAppear { refresh() }
        .onReceive(timer) { _ in if autoRefresh { refresh() } }
    }

    private func refresh() { text = LlamaBridge.collectedLog() }

    private func share() {
        guard let url = ChatExporter.tempFile(named: "opentihui-log", ext: "txt",
                                              data: Data(text.utf8)) else { return }
        exportFile = ExportFile(url: url)
    }
}
