//
//  ComposeView.swift
//  openTihui
//
//  Generation surface opened by the openTihui keyboard. The user came from
//  another app's text field; here they tune the task (instruction, $variables,
//  text, images), generate on-device or via API, pick the result, and it's
//  copied back so the keyboard can insert it. Images can be taken with the
//  camera, picked from the album, or auto-filled from a recent screenshot.
//

import SwiftUI
import PhotosUI

struct ComposeView: View {
    let request: ComposeRequest
    @EnvironmentObject var chat: ChatViewModel
    @EnvironmentObject var shortcuts: ShortcutStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var rawInstruction: String
    @State private var instruction: String          // editable when no variables
    @State private var context: String
    @State private var variableValues: [String: String] = [:]
    @State private var variableDefs: [PromptVariableDef] = []
    @State private var variableScope = ""
    @State private var result = ""
    @State private var isBusy = false
    @State private var preparing = false
    @State private var copied = false

    @State private var images: [UIImage] = []
    @State private var imagePaths: [String] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false

    // Per-compose generation settings (model + full GenConfig), tunable in the
    // "Generation settings" page. Seeded from the originating shortcut / defaults.
    @State private var composeConfig: GenConfig = .default
    @State private var modelSelection: String?      // nil = inherit the chat's current model
    @State private var settingsLoaded = false

    // Per-line result selection (default = all lines until the user picks one).
    @State private var selectedLines: Set<Int> = []
    @State private var hasManuallySelected = false

    private var variables: [PromptVariable] { PromptTemplate.variables(in: rawInstruction, defs: variableDefs) }

    init(request: ComposeRequest) {
        self.request = request
        _rawInstruction = State(initialValue: request.instruction ?? "")
        _instruction = State(initialValue: request.instruction ?? "")
        _context = State(initialValue: request.context)
    }

    var body: some View {
        NavigationStack {
            Form {
                if variables.isEmpty {
                    Section("Instruction") {
                        TextField("What should openTihui do?", text: $instruction, axis: .vertical)
                            .lineLimit(1...4)
                    }
                } else {
                    Section("Options") {
                        ForEach(variables) { v in variableRow(v) }
                    }
                }

                if chat.composeVisionAvailable {
                    Section("Images") {
                        if !images.isEmpty { imageStrip }
                        HStack(spacing: 20) {
                            if CameraPicker.isAvailable {
                                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                                    .buttonStyle(.borderless)
                            }
                            PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                                Label("Choose from Album", systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                        }
                    }
                }

                Section(context.isEmpty ? "Text" : "Text to use") {
                    TextField("Type or edit the text…", text: $context, axis: .vertical).lineLimit(1...10)
                }

                Section {
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text(result.isEmpty ? "Generate" : "Regenerate")
                            if isBusy || preparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isBusy || preparing || (instruction.isEmpty && context.isEmpty && imagePaths.isEmpty && variables.isEmpty))
                } footer: {
                    Text("Using \(selectedModelName)\(selectionIsRemote ? " (API)" : " on-device").")
                }

                Section {
                    NavigationLink {
                        generationSettings
                    } label: {
                        Label("Generation settings", systemImage: "slider.horizontal.3")
                    }
                }

                if !result.isEmpty || isBusy {
                    let split = splitReasoning(result)
                    let answerLines = split.answer.components(separatedBy: "\n").enumerated()
                        .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { (index: $0.offset, text: $0.element) }
                    Section {
                        if split.thinking != nil || split.isThinking {
                            ThinkingView(text: split.thinking ?? "", isLive: isBusy && split.isThinking)
                        }
                        // Each generated line is selectable (Markdown-rendered).
                        ForEach(answerLines, id: \.index) { line in
                            Button { toggleLine(line.index) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: isLineSelected(line.index) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isLineSelected(line.index) ? Color.accentColor : Color.secondary)
                                    Text(inlineMarkdown(line.text)).foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                        }
                    } header: {
                        HStack {
                            Text("Result")
                            Spacer()
                            if !isBusy && !answerLines.isEmpty {
                                Button("Select All") { selectAllLines(answerLines.map { $0.index }) }
                                Text("·").foregroundStyle(.tertiary)
                                Button("None") { selectNoLines() }
                            }
                        }
                        .textCase(nil)
                    }

                    Section {
                        Button { copySelected(answerLines) } label: {
                            Label(copied ? "Copied — switch back & tap Insert" : "Use selected lines",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                        .disabled(isBusy || !answerLines.contains { isLineSelected($0.index) })
                    }
                }
            }
            .navigationTitle("openTihui")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                }
            }
            .task { await prepare() }
            .onChange(of: photoItems) { _, items in if !items.isEmpty { Task { await loadPhotos(items) } } }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(isPresented: $showCamera) { data in addImage(data) }.ignoresSafeArea()
            }
        }
    }

    /// Full per-compose tuning: model + the shared generation config (context,
    /// reasoning, sampling, image compression, …).
    private var generationSettings: some View {
        Form {
            Section {
                Picker("Model", selection: $modelSelection) {
                    Text("Default (\(chat.resolvedModelName))").tag(String?.none)
                    if !chat.models.models.isEmpty {
                        Section("On-device") {
                            ForEach(chat.models.models) { Text($0.name).tag(String?.some($0.modelPath)) }
                        }
                    }
                    if !chat.remotes.endpoints.isEmpty {
                        Section("API") {
                            ForEach(chat.remotes.endpoints) { Label($0.name, systemImage: "cloud").tag(String?.some($0.selectionTag)) }
                        }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("On-device models load with the context length below; API endpoints ignore local settings.")
            }
            GenConfigEditor(config: $composeConfig)
        }
        .navigationTitle("Generation settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images.indices, id: \.self) { i in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: images[i]).resizable().scaledToFill()
                            .frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 8))
                        Button { removeImage(i) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.5)).font(.body)
                        }
                        .padding(3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func variableRow(_ v: PromptVariable) -> some View {
        if v.isSelection {
            Picker(v.label, selection: Binding(
                get: { variableValues[v.name] ?? v.defaultValue },
                set: { variableValues[v.name] = $0; chat.rememberVariableValue(v.name, scope: variableScope, $0) })) {
                ForEach(v.options, id: \.self) { Text($0).tag($0) }
            }
        } else {
            HStack {
                Text(v.label).foregroundStyle(.secondary)
                TextField(v.label, text: Binding(
                    get: { variableValues[v.name] ?? "" },
                    set: { variableValues[v.name] = $0; chat.rememberVariableValue(v.name, scope: variableScope, $0) }))
                .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: images

    /// Image downscaling for this compose (tunable in Generation settings).
    private var imageMaxDimension: Int { composeConfig.imageMaxDimension }

    /// Name of the model the compose will actually use (override, else the chat's).
    private var selectedModelName: String {
        guard let sel = modelSelection else { return chat.resolvedModelName }
        if sel.hasPrefix("remote:") {
            return chat.remotes.endpoints.first(where: { $0.selectionTag == sel })?.name ?? chat.resolvedModelName
        }
        return chat.models.models.first(where: { $0.modelPath == sel })?.name ?? chat.resolvedModelName
    }
    private var selectionIsRemote: Bool {
        if let sel = modelSelection { return sel.hasPrefix("remote:") }
        return chat.isRemote
    }

    private func addImage(_ data: Data) {
        guard let img = UIImage(data: data),
              let url = AttachmentStore.saveImage(data, maxDimension: imageMaxDimension) else { return }
        images.append(img)
        imagePaths.append(url.path)
    }

    private func removeImage(_ i: Int) {
        guard images.indices.contains(i) else { return }
        images.remove(at: i)
        imagePaths.remove(at: i)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { addImage(data) }
        }
        photoItems = []
    }

    // MARK: flow

    private func prepare() async {
        // Recover the *live* shortcut (with its $variables) so the user can tune
        // it — even if the keyboard handed over a stale, pre-resolved instruction.
        let sc = resolveShortcut()
        if let s = sc {
            rawInstruction = s.systemPrompt
            instruction = s.systemPrompt
            variableDefs = s.variableDefs
            variableScope = s.name
        }
        // Seed generation settings from the shortcut, else the app defaults.
        if !settingsLoaded {
            composeConfig = sc?.config ?? settings.defaultConfig
            modelSelection = sc?.modelPath          // nil → inherit the chat's current model
            settingsLoaded = true
        }
        // Seed variables, preferring the user's last remembered choice.
        for v in variables where (variableValues[v.name] ?? "").isEmpty {
            let seeded = chat.rememberedVariableValue(v.name, scope: variableScope, default: v.isSelection ? v.defaultValue : "")
            if !seeded.isEmpty { variableValues[v.name] = seeded }
        }
        // Auto-fill from the clipboard only when enabled AND no text was handed
        // over (nothing was selected / before the cursor when compose opened).
        if composeConfig.autoClipboard,
           context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let clip = UIPasteboard.general.string,
           !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context = clip
        }
        // Auto-attach the latest screenshot taken in the last 30s (asks for Photos
        // access) — only when enabled and the model can use images.
        if composeConfig.autoScreenshot, chat.composeVisionAvailable {
            preparing = true
            if let img = await ScreenshotSuggester.recentScreenshot(),
               let data = img.jpegData(compressionQuality: 0.9),
               let url = AttachmentStore.saveImage(data, maxDimension: imageMaxDimension) {
                images.append(img)
                imagePaths.append(url.path)
            }
            preparing = false
        }
        // Auto-generate once on open when there's something to act on and nothing
        // to tune (no variables). Changing an option / adding an image doesn't
        // re-trigger this; the user taps Generate.
        let hasContent = !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imagePaths.isEmpty
        if hasContent && (!instruction.isEmpty || !variables.isEmpty) {
            await generate()
        }
    }

    /// Find the live shortcut this compose came from: by name (new keyboards),
    /// else by matching the handed-over instruction to a shortcut's default
    /// resolution (older keyboards that sent a pre-resolved instruction).
    private func resolveShortcut() -> Shortcut? {
        if let name = request.shortcutName,
           let s = shortcuts.shortcuts.first(where: { $0.name == name }) { return s }
        let instr = (request.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty else { return nil }
        return shortcuts.shortcuts.first {
            PromptTemplate.resolve($0.systemPrompt, defs: $0.variableDefs, values: [:]).trimmingCharacters(in: .whitespacesAndNewlines) == instr
        }
    }

    private func generate() async {
        guard !isBusy else { return }
        isBusy = true
        result = ""
        copied = false
        selectedLines = []; hasManuallySelected = false   // new result → default to all lines
        let instr = variables.isEmpty ? instruction
            : PromptTemplate.resolve(rawInstruction, defs: variableDefs, values: variableValues)
        result = await chat.composeGenerate(request: instr, context: context, imagePaths: imagePaths,
                                            config: composeConfig, modelSelection: modelSelection) { partial in
            result = partial
        }
        isBusy = false
    }

    // MARK: result line selection + rich-text copy

    private func isLineSelected(_ i: Int) -> Bool { hasManuallySelected ? selectedLines.contains(i) : true }

    private func toggleLine(_ i: Int) {
        if hasManuallySelected {
            if selectedLines.contains(i) { selectedLines.remove(i) } else { selectedLines.insert(i) }
        } else {
            selectedLines = [i]           // first pick from the "all selected" default → just this line
            hasManuallySelected = true
        }
    }

    private func selectAllLines(_ indices: [Int]) { selectedLines = Set(indices); hasManuallySelected = true }
    private func selectNoLines() { selectedLines = []; hasManuallySelected = true }

    /// Inline Markdown (bold/italic/code/links) for a single result line.
    private func inlineMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// Copy the selected lines as **rich text** (RTF) + a plain-text fallback (no
    /// raw Markdown), then dismiss so the user can Insert it via the keyboard.
    private func copySelected(_ lines: [(index: Int, text: String)]) {
        let chosen = lines.filter { isLineSelected($0.index) }.map { $0.text }
        guard !chosen.isEmpty else { return }
        let attr = MarkdownAttributed.make(chosen.joined(separator: "\n"), color: .label)
        var item: [String: Any] = ["public.utf8-plain-text": attr.string]
        if let rtf = try? attr.data(from: NSRange(location: 0, length: attr.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item["public.rtf"] = rtf
        }
        UIPasteboard.general.items = [item]
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
    }
}
