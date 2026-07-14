//
//  ChatView.swift
//  openTihui
//
//  iMessage-style conversation detail: a scrolling list of bubbles with a
//  composer that has a "+" attachments button. Pushed from ChatListView.
//

import SwiftUI
import PhotosUI

struct ChatDetailView: View {
    @EnvironmentObject var chat: ChatViewModel

    @State private var input = ""
    @State private var pendingAttachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showChatSettings = false
    @State private var showExportDialog = false
    @State private var exportFile: ExportFile?
    @State private var isExporting = false
    @StateObject private var screenshots = ScreenshotSuggester()
    @StateObject private var recorder = AudioRecorder()
    @State private var editingVariable: PromptVariable?
    @State private var variableInput = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let err = chat.loadError { errorBanner(err) }
            if let note = chat.loadNotice { noticeBanner(note) }
            if chat.isModelReady { contextBar }
            else if chat.isLoadingModel { loadingBar }
            else if chat.hasAvailableModel { modelLoadBar }
            else { loadModelBanner }
            messageList
        }
        // Pin the composer above the keyboard so the send button is never hidden.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let shot = screenshots.image, chat.supportsVision, chat.config.autoScreenshot { screenshotFloat(shot) }
                if !chat.promptVariables.isEmpty { variableBar }
                if !pendingAttachments.isEmpty { pendingAttachmentBar }
                inputBar
            }
        }
        .alert(editingVariable?.label ?? "Value",
               isPresented: Binding(get: { editingVariable != nil }, set: { if !$0 { editingVariable = nil } })) {
            TextField("Value", text: $variableInput)
            Button("Set") {
                if let v = editingVariable { Task { await chat.setVariable(v.name, variableInput) } }
                editingVariable = nil
            }
            Button("Cancel", role: .cancel) { editingVariable = nil }
        }
        .onAppear { if chat.supportsVision { screenshots.start() }; autoFillClipboardIfNeeded() }
        .onDisappear { screenshots.stop() }
        .onChange(of: chat.currentConversationID) { _, _ in autoFillClipboardIfNeeded() }
        .onChange(of: chat.supportsVision) { _, vision in
            if vision { screenshots.start() } else { screenshots.stop(); screenshots.dismiss() }
        }
        .navigationTitle(chat.currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)   // full-screen chat: hide the tab bar
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in Task { await loadPhotos(items) } }
        .onChange(of: recorder.isRecording) { _, rec in if !rec { attachFinishedRecording() } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(isPresented: $showCamera) { data in
                if let url = AttachmentStore.saveImage(data, maxDimension: chat.config.imageMaxDimension) {
                    pendingAttachments.append(Attachment(kind: .image, url: url))
                }
            }
            .ignoresSafeArea()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { reasoningMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showChatSettings = true } label: { Label("Chat Settings", systemImage: "slider.horizontal.3") }
                    if !chat.messages.isEmpty {
                        Button { showExportDialog = true } label: { Label("Export Chat", systemImage: "square.and.arrow.up") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showChatSettings) {
            ChatSettingsView()
        }
        .confirmationDialog("Export this chat", isPresented: $showExportDialog, titleVisibility: .visible) {
            Button("Export as PDF") { exportChat(pdf: true) }
            Button("Export as JSON") { exportChat(pdf: false) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .overlay { if isExporting { ExportingOverlay(label: "Preparing export…") } }
        .animation(.easeInOut(duration: 0.2), value: isExporting)
    }

    private func exportChat(pdf: Bool) {
        let title = chat.currentTitle
        let messages = chat.messages
        let model = chat.resolvedModelName
        let systemPrompt = chat.systemPromptOverride
        let subtitle = "\(model) · \(Date().formatted(date: .abbreviated, time: .shortened))"
        isExporting = true
        // The whole export (Core Text render / image embedding) runs off-main so
        // the overlay stays live.
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

    // MARK: Sub-views

    private var loadModelBanner: some View {
        statusBanner("Add a model from **Models** to start chatting.", system: "exclamationmark.circle")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption)
            Spacer()
            Button { chat.loadError = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    /// Informational (non-error) banner, e.g. "ternary quants → running on CPU".
    private func noticeBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text(message).font(.caption)
            Spacer()
            Button { chat.loadNotice = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
    }

    private var loadingBar: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Loading \(chat.resolvedModelName)…").font(.caption).lineLimit(1)
                Spacer()
                if chat.loadProgress > 0 {
                    Text("\(Int(chat.loadProgress * 100))%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if chat.loadProgress > 0 {
                ProgressView(value: min(chat.loadProgress, 1), total: 1)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
    }

    /// Shown when the chat's model isn't loaded yet — explicit Load button.
    private var modelLoadBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
            Text(chat.resolvedModelName).font(.caption).lineLimit(1)
            Spacer()
            Button("Load") { Task { await chat.ensureModelLoaded() } }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
    }

    private func statusBanner(_ text: String, system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
            Text(.init(text)).font(.caption)
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var contextBar: some View {
        if chat.isRemote {
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill").foregroundStyle(.secondary)
                Text(chat.resolvedModelName).font(.caption).bold().lineLimit(1)
                Spacer()
                Text("API").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 6)
            .background(.bar)
        } else {
            let usage = chat.contextUsage
            let frac = usage.total > 0 ? Double(usage.past) / Double(usage.total) : 0
            VStack(spacing: 2) {
                HStack {
                    Text(chat.loadedModel?.name ?? "")
                        .font(.caption).bold().lineLimit(1)
                    Spacer()
                    Text("ctx \(usage.past)/\(usage.total)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ProgressView(value: min(frac, 1.0))
                    .tint(frac > 0.9 ? .orange : .accentColor)
            }
            .padding(.horizontal).padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(chat.messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if chat.messages.isEmpty && !chat.isReplaying {
                    ContentUnavailableView("Say hello", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("Send a message to start the conversation."))
                }
                if chat.isReplaying {
                    ProgressView("Restoring chat…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var pendingAttachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if att.kind == .image, let img = UIImage(contentsOfFile: att.url.path) {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
                                    .frame(width: 56, height: 56)
                                    .overlay(Image(systemName: "waveform"))
                            }
                        }
                        Button {
                            pendingAttachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8)
        }
    }

    private var reasoningMenu: some View {
        Menu {
            Picker("Thinking effort", selection: $chat.thinkingEffort) {
                ForEach(ThinkingEffort.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chat.thinkingEffort == .off ? "brain.head.profile" : "brain")
                Text(chat.thinkingEffort.label).font(.subheadline)
            }
            .foregroundStyle(chat.thinkingEffort == .off ? Color.secondary : Color.accentColor)
        }
    }

    /// The "+" attachments button: photos/camera for vision models, audio
    /// recording for audio-capable ones (e.g. Gemma with its audio projector).
    @ViewBuilder
    private var addButton: some View {
        if recorder.isRecording {
            Button { recorder.stop() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                    Text(recordingTime).font(.caption.monospacedDigit())
                }
                .foregroundStyle(.red)
            }
        } else {
            Menu {
                if chat.supportsVision {
                    Button { showPhotoPicker = true } label: { Label("Photos", systemImage: "photo") }
                    if CameraPicker.isAvailable {
                        Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                    }
                }
                if chat.supportsAudio {
                    Button { startRecording() } label: { Label("Record Audio", systemImage: "mic") }
                }
                if !chat.supportsVision && !chat.supportsAudio {
                    Label("This model is text-only", systemImage: "textformat")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle((chat.supportsVision || chat.supportsAudio) ? Color.accentColor : Color.secondary)
                    .frame(width: 38, height: 38)
            }
            .composerGlass(Circle(), interactive: true)
            .disabled(!chat.supportsVision && !chat.supportsAudio)
        }
    }

    /// Elapsed recording time as `M:SS` (the recorder auto-stops at its cap).
    private var recordingTime: String {
        let e = Int(recorder.elapsed)
        return String(format: "%d:%02d", e / 60, e % 60)
    }

    private func startRecording() {
        recorder.requestPermission { granted in
            if granted { recorder.start() }
        }
    }

    /// Append the finished recording when recording ends — whether the user
    /// stopped it or it hit the duration cap.
    private func attachFinishedRecording() {
        if let url = recorder.takeRecording() {
            pendingAttachments.append(Attachment(kind: .audio, url: url))
        }
    }

    private func screenshotFloat(_ img: UIImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("Add screenshot?").font(.subheadline.weight(.medium))
                Text("Attach your latest screenshot").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add") { addScreenshot(img) }.buttonStyle(.borderedProminent).controlSize(.small)
            Button { screenshots.dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func addScreenshot(_ img: UIImage) {
        if let data = img.jpegData(compressionQuality: 0.9), let url = AttachmentStore.saveImage(data, maxDimension: chat.config.imageMaxDimension) {
            pendingAttachments.append(Attachment(kind: .image, url: url))
        }
        screenshots.dismiss()
    }

    /// Auto-fill the composer from the clipboard when the chat enables it.
    private func autoFillClipboardIfNeeded() {
        guard chat.config.autoClipboard,
              input.trimmingCharacters(in: .whitespaces).isEmpty,
              let clip = UIPasteboard.general.string,
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = clip
    }

    /// Controls for `$variables` in the chat's system prompt (e.g. translation language).
    private var variableBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chat.promptVariables) { v in
                    if v.isSelection {
                        Menu {
                            ForEach(v.options, id: \.self) { opt in
                                Button { Task { await chat.setVariable(v.name, opt) } } label: {
                                    if currentValue(v) == opt { Label(opt, systemImage: "checkmark") } else { Text(opt) }
                                }
                            }
                        } label: { variableChip(v) }
                    } else {
                        Button {
                            variableInput = chat.variableValues[v.name] ?? ""
                            editingVariable = v
                        } label: { variableChip(v) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func currentValue(_ v: PromptVariable) -> String {
        let val = chat.variableValues[v.name] ?? ""
        return val.isEmpty ? v.defaultValue : val
    }

    private func variableChip(_ v: PromptVariable) -> some View {
        let val = currentValue(v)
        return HStack(spacing: 4) {
            Text("\(v.label):").foregroundStyle(.secondary)
            Text(val.isEmpty ? "Set…" : val).fontWeight(.medium).foregroundStyle(.primary)
            Image(systemName: v.isSelection ? "chevron.up.chevron.down" : "pencil")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Keyboard-dismiss "Done" lives on the left while editing.
            if inputFocused {
                Button { inputFocused = false } label: {
                    Text("Done").font(.subheadline.weight(.semibold))
                        .frame(height: 38).padding(.horizontal, 14)
                        .foregroundStyle(.secondary)
                }
                .composerGlass(Capsule(), interactive: true)
            }

            addButton

            TextField("Message…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .composerGlass(Capsule())

            if chat.isGenerating {
                Button { chat.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 34)).foregroundStyle(.red)
                }
            } else {
                let canSend = !(input.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty)
                Button { sendMessage() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .sendButtonGlass()
                        .shadow(color: Color.accentColor.opacity(canSend ? 0.45 : 0), radius: 6, y: 2)
                        .opacity(canSend ? 1 : 0.45)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    // MARK: Actions

    private func sendMessage() {
        let text = input
        let atts = pendingAttachments     // only what the user actually attached (incl. an Added screenshot)
        input = ""
        pendingAttachments = []
        photoItems = []
        Task {
            if !chat.isModelReady { await chat.ensureModelLoaded() }
            await chat.compactIfNeeded()
            chat.send(text: text, attachments: atts)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let url = AttachmentStore.saveImage(data, maxDimension: chat.config.imageMaxDimension) {
                pendingAttachments.append(Attachment(kind: .image, url: url))
            }
        }
        await MainActor.run { photoItems = [] }
    }

}

private extension View {
    /// Liquid Glass on iOS 26+, with a material fallback on older systems.
    @ViewBuilder
    func composerGlass(_ shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// The send button: an accent-tinted Liquid Glass circle on iOS 26+, a solid
    /// accent circle on older systems.
    @ViewBuilder
    func sendButtonGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
        } else {
            self.background(Color.accentColor, in: Circle())
        }
    }
}
