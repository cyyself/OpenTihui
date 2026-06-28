//
//  ChatListView.swift
//  openTihui
//
//  Messages-style root list of conversations. Tapping a row opens the chat;
//  the toolbar gives access to Models, Settings and a new chat.
//

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var convos: ConversationStore
    @EnvironmentObject var chat: ChatViewModel

    var onOpen: (UUID) -> Void
    var onNew: () -> Void

    @State private var exportFile: ExportFile?
    @State private var isExporting = false

    var body: some View {
        Group {
            if convos.conversations.isEmpty {
                ContentUnavailableView {
                    Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Tap the compose button to start a conversation.")
                } actions: {
                    Button("New Chat") { onNew() }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(convos.conversations) { convo in
                        Button { onOpen(convo.id) } label: { row(convo) }
                            .tint(.primary)
                            .contextMenu {
                                Button { exportConvo(convo, pdf: true) } label: { Label("Export as PDF", systemImage: "doc.richtext") }
                                Button { exportConvo(convo, pdf: false) } label: { Label("Export as JSON", systemImage: "curlybraces") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { exportConvo(convo, pdf: true) } label: { Label("Export", systemImage: "square.and.arrow.up") }.tint(.indigo)
                            }
                    }
                    .onDelete { offsets in
                        Task { for i in offsets { await chat.deleteConversation(convos.conversations[i].id) } }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            if !convos.conversations.isEmpty {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { onNew() } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .overlay { if isExporting { ExportingOverlay(label: "Preparing export…") } }
        .animation(.easeInOut(duration: 0.2), value: isExporting)
    }

    private func exportConvo(_ convo: Conversation, pdf: Bool) {
        let messages = convo.messages.map { ChatMessage(stored: $0) }
        let title = convo.title.isEmpty ? "Chat" : convo.title
        let model = convo.modelName
        let systemPrompt = convo.systemPrompt
        let subtitle = "\(model ?? "openTihui") · \(convo.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        isExporting = true
        Task { @MainActor in
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                if pdf {
                    let data = ChatExporter.pdfData(title: title, subtitle: subtitle, messages: messages)
                    return ChatExporter.tempFile(named: title, ext: "pdf", data: data)
                } else {
                    guard let data = try? ChatExporter.jsonData(title: title, model: model, systemPrompt: systemPrompt,
                                                                messages: messages, exportedAt: Date()) else { return nil }
                    return ChatExporter.tempFile(named: title, ext: "json", data: data)
                }
            }.value
            isExporting = false
            if let url { exportFile = ExportFile(url: url) }
        }
    }

    private func row(_ convo: Conversation) -> some View {
        let preview = lastPreview(convo)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: convo.icon ?? "bubble.left.fill").foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(convo.title.isEmpty ? "New Chat" : convo.title)
                        .font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(convo.updatedAt, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(preview)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func lastPreview(_ convo: Conversation) -> String {
        guard let last = convo.messages.last else { return "No messages yet" }
        let text = splitReasoning(last.text).answer
        let body = text.isEmpty ? (last.attachments.isEmpty ? "…" : "📎 Attachment") : text
        let prefix = last.role == "assistant" ? "" : "You: "
        return prefix + body.replacingOccurrences(of: "\n", with: " ")
    }
}
