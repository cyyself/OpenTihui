//
//  ContentView.swift
//  openTihui
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var chat: ChatViewModel

    enum Tab { case chat, shortcuts, settings }

    @State private var selectedTab = Tab.chat
    @State private var chatPath: [UUID] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $chatPath) {
                ChatListView(
                    onOpen: { id in
                        chatPath.append(id)
                        Task { await chat.selectConversation(id) }
                    },
                    onNew: {
                        Task {
                            await chat.newConversation()
                            chatPath.append(chat.currentConversationID)
                        }
                    }
                )
                .navigationDestination(for: UUID.self) { _ in ChatDetailView() }
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            .tag(Tab.chat)

            NavigationStack {
                ShortcutsView(onRun: { shortcut in
                    Task {
                        await chat.startShortcut(shortcut)
                        chatPath = [chat.currentConversationID]
                        selectedTab = .chat
                    }
                })
            }
            .tabItem { Label("Shortcuts", systemImage: "sparkles") }
            .tag(Tab.shortcuts)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
    }
}
