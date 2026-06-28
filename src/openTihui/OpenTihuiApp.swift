//
//  OpenTihuiApp.swift
//  openTihui
//
//  On-device LLaMA / Qwen-VL chat powered by llama.cpp + libmtmd.
//

import SwiftUI

@main
struct OpenTihuiApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ModelStore()
    @StateObject private var conversations = ConversationStore()
    @StateObject private var shortcuts = ShortcutStore()
    @StateObject private var remotes = RemoteStore()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var compose = ComposeBridge()
    @StateObject private var chat: ChatViewModel
    @State private var importedShortcutName: String?

    init() {
        let engine = InferenceEngine()
        let convoStore = ConversationStore()
        let modelStore = ModelStore()
        let remoteStore = RemoteStore()
        _conversations = StateObject(wrappedValue: convoStore)
        _store = StateObject(wrappedValue: modelStore)
        _remotes = StateObject(wrappedValue: remoteStore)
        _chat = StateObject(wrappedValue: ChatViewModel(engine: engine, store: convoStore, models: modelStore, remotes: remoteStore, settings: AppSettings.shared))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(conversations)
                .environmentObject(shortcuts)
                .environmentObject(remotes)
                .environmentObject(downloads)
                .environmentObject(compose)
                .environmentObject(chat)
                .task {
                    InferenceEngine.warmGPUAvailability()   // probe Metal off-main so Settings never blocks
                    if SmokeTest.isEnabled { SmokeTest.run() }
                }
                .onOpenURL { url in
                    if url.isFileURL {
                        if let s = shortcuts.importFromFile(url) { importedShortcutName = s.name }
                    } else {
                        compose.handle(url)
                    }
                }
                .sheet(item: $compose.request) { req in
                    ComposeView(request: req).environmentObject(chat).environmentObject(shortcuts).environmentObject(settings)
                }
                .alert("Shortcut imported", isPresented: Binding(get: { importedShortcutName != nil }, set: { if !$0 { importedShortcutName = nil } })) {
                    Button("OK") { importedShortcutName = nil }
                } message: {
                    Text("“\(importedShortcutName ?? "")” was added to your Shortcuts.")
                }
        }
    }
}
