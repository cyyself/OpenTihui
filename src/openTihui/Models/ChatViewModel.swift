//
//  ChatViewModel.swift
//  openTihui
//
//  Owns the active conversation and turns chat turns into ChatML prompt deltas
//  fed incrementally into the KV cache. Conversations are persisted via
//  `ConversationStore`; switching a conversation replays its history into the
//  model so context is preserved. Targets ChatML models such as Qwen3-VL.
//

import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isGenerating = false
    @Published var loadedModel: ManagedModel?
    @Published var loadError: String?
    @Published var isLoadingModel = false
    @Published var contextUsage: (past: Int, total: Int) = (0, 0)
    @Published var isReplaying = false
    @Published var loadProgress: Double = 0   // 0…1 while a model is loading
    /// Thread-safe snapshot of the loaded model; the UI reads this instead of
    /// touching the live model pointer (which the inference queue may be freeing).
    @Published var modelSnapshot: ModelSnapshot?

    @Published private(set) var currentConversationID = UUID()
    @Published private(set) var currentTitle = "New Chat"
    @Published private(set) var icon = "bubble.left.fill"
    /// The model this chat prefers (nil = use the global default). Resolved lazily.
    @Published private(set) var pinnedModelPath: String?

    /// Per-chat generation config (context, sampling, reasoning) and system prompt.
    @Published private(set) var config = GenConfig.default
    @Published private(set) var systemPromptOverride: String?

    /// Values chosen for `$variables` in the system prompt (e.g. translation
    /// language). Substituted into the prompt before it reaches the model.
    @Published private(set) var variableValues: [String: String] = [:]


    /// Variable definitions (name + options) for this chat's system prompt.
    @Published private(set) var variableDefs: [PromptVariableDef] = []

    /// Namespace for remembered variable values (the shortcut name), so the same
    /// variable name used by different shortcuts doesn't collide.
    private(set) var variableScope = ""

    /// Variables referenced by the active system prompt, with options from defs.
    var promptVariables: [PromptVariable] { PromptTemplate.variables(in: rawSystemPrompt, defs: variableDefs) }
    private var rawSystemPrompt: String { systemPromptOverride ?? settings.systemPrompt }
    private func resolvedSystemPrompt() -> String {
        PromptTemplate.resolve(rawSystemPrompt, defs: variableDefs, values: variableValues)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scoped key for remembered values: `<scope>\u{1}<name>` (or just `<name>`).
    static func scopedKey(_ scope: String, _ name: String) -> String {
        scope.isEmpty ? name : "\(scope)\u{1}\(name)"
    }

    /// Seed any variable with no value yet, preferring the user's last choice
    /// (remembered per shortcut) and falling back to the default option.
    private func seedVariableDefaults() {
        for v in promptVariables where (variableValues[v.name] ?? "").isEmpty {
            let remembered = settings.lastVariableValues[Self.scopedKey(variableScope, v.name)]
            if let remembered, !remembered.isEmpty {
                variableValues[v.name] = remembered
            } else if v.isSelection {
                variableValues[v.name] = v.defaultValue
            }
        }
    }

    /// The remembered last value for a variable in a given scope, or the default.
    func rememberedVariableValue(_ name: String, scope: String, default def: String) -> String {
        let v = settings.lastVariableValues[Self.scopedKey(scope, name)]
        return (v?.isEmpty == false) ? v! : def
    }

    /// Remember a variable choice for next time, scoped to its shortcut.
    func rememberVariableValue(_ name: String, scope: String, _ value: String) {
        guard !value.isEmpty else { return }
        settings.lastVariableValues[Self.scopedKey(scope, name)] = value
    }

    /// Change a variable value and rebuild context so the new system prompt
    /// takes effect (local: replay; remote: nothing to reload).
    func setVariable(_ name: String, _ value: String) async {
        guard variableValues[name] != value else { return }
        variableValues[name] = value
        rememberVariableValue(name, scope: variableScope, value)   // remember the user's choice
        persistCurrent()
        if !isRemote, isModelReady { await replayHistory() }
    }

    /// Quick reasoning toggle bound by the chat toolbar; writes through to `config`.
    @Published var thinkingEffort: ThinkingEffort = .low {
        didSet {
            guard !applyingConfig, thinkingEffort != config.thinkingEffort else { return }
            config.thinkingEffort = thinkingEffort
            persistCurrent()
        }
    }

    /// Remote API endpoint this chat uses (nil = local model).
    @Published private(set) var remoteEndpointID: String?

    let engine: InferenceEngine
    let store: ConversationStore
    let models: ModelStore
    let remotes: RemoteStore
    private let settings: AppSettings

    private var createdAt = Date()
    private var isFirstUserTurn = true
    private var genTask: Task<Void, Never>?
    private var applyingConfig = false   // suppress reacting to programmatic config changes
    /// Index of the oldest message kept in the model's context. Earlier messages
    /// stay visible but are dropped from the KV cache (auto-compaction). Used for
    /// M-RoPE models (Qwen-VL) where position-shift compaction isn't possible.
    private var contextStart = 0

    init(engine: InferenceEngine, store: ConversationStore, models: ModelStore, remotes: RemoteStore, settings: AppSettings) {
        self.engine = engine
        self.store = store
        self.models = models
        self.remotes = remotes
        self.settings = settings
        thinkingEffort = config.thinkingEffort
    }

    // MARK: Remote endpoints

    var currentRemoteEndpoint: RemoteEndpoint? {
        remoteEndpointID.flatMap { remotes.endpoint(tagID: $0) }
    }
    var isRemote: Bool { currentRemoteEndpoint != nil }

    private func setConfig(_ newConfig: GenConfig, systemPrompt: String?) {
        applyingConfig = true
        config = newConfig
        systemPromptOverride = systemPrompt
        thinkingEffort = newConfig.thinkingEffort
        applyingConfig = false
    }

    /// A model the chat can auto-load: the last-loaded one if still present,
    /// otherwise the first available.
    /// The model this chat should use: its pinned model, else the default, else
    /// any — skipping any whose file has been removed from disk.
    var resolvedModel: ManagedModel? {
        for path in [pinnedModelPath, settings.defaultModelPath, settings.lastModelPath] {
            if let path, let m = models.models.first(where: { $0.modelPath == path }), m.modelExists { return m }
        }
        return models.models.first(where: { $0.modelExists })
    }

    var resolvedModelName: String {
        if let r = currentRemoteEndpoint { return r.name }
        return resolvedModel?.name ?? "No model"
    }
    var hasAvailableModel: Bool { isRemote || resolvedModel != nil }
    /// Ready to chat: a remote endpoint is selected, or the local model is loaded.
    var isModelReady: Bool { isRemote || (loadedModel != nil && loadedModel?.modelPath == resolvedModel?.modelPath) }

    var modelInfo: ModelSnapshot? { modelSnapshot }
    var supportsVision: Bool { isRemote ? (currentRemoteEndpoint?.supportsVision ?? false) : (modelSnapshot?.supportsVision ?? false) }
    var supportsAudio: Bool { isRemote ? false : (modelSnapshot?.supportsAudio ?? false) }

    /// Whether images can be attached — authoritative once a model is loaded,
    /// otherwise predicted from the resolved model + projector setting so we can
    /// decide to attach a screenshot *before* a (slow) cold load.
    var canUseImages: Bool {
        if isRemote { return currentRemoteEndpoint?.supportsVision ?? false }
        if let snap = modelSnapshot { return snap.supportsVision }
        return (resolvedModel?.hasMultimodal ?? false) && needsProjector
    }

    /// Whether the compose-in-app surface can attach images — a remote vision
    /// endpoint, or any on-device model that ships a projector (compose forces
    /// the projector to load for image queries, ignoring the per-chat toggle).
    var composeVisionAvailable: Bool {
        isRemote ? (currentRemoteEndpoint?.supportsVision ?? false) : (resolvedModel?.hasMultimodal ?? false)
    }

    /// Load the vision projector when the chat wants it — explicitly, or because
    /// auto-screenshot is on (which needs vision to be useful).
    private var needsProjector: Bool { config.loadProjector || config.autoScreenshot }

    // MARK: Model lifecycle

    func loadModel(_ model: ManagedModel, contextLength ctxOverride: Int? = nil, projectorOverride: Bool? = nil) async {
        // The file may have been deleted (Files app, external) since it was listed.
        guard model.modelExists else {
            loadError = "“\(model.name)” is missing — its file may have been deleted. Re-add it from the Models tab."
            models.reload()                 // drop the stale entry from the list
            return
        }
        isLoadingModel = true
        loadProgress = 0
        loadError = nil
        do {
            let snap = try await engine.load(model: model, contextLength: ctxOverride ?? config.contextLength,
                                             gpuEnabled: settings.gpuEnabled, useProjector: projectorOverride ?? needsProjector,
                                             onProgress: { [weak self] p in
                                                 Task { @MainActor in self?.loadProgress = p }
                                             })
            loadedModel = model
            modelSnapshot = snap
            settings.lastModelPath = model.modelPath   // remember for next launch / auto-load
            // Rebuild context for whatever conversation is currently open.
            await replayHistory()
        } catch {
            loadError = error.localizedDescription
            loadedModel = nil
            modelSnapshot = nil
        }
        isLoadingModel = false
    }

    /// Unload the current model and clear its snapshot.
    func unload() {
        genTask?.cancel()
        isGenerating = false
        engine.unload()
        loadedModel = nil
        modelSnapshot = nil
        contextUsage = (0, 0)
    }

    /// Ensure the chat's resolved model is loaded (loading/switching if needed).
    /// Called explicitly (Load button / send) and as a background warm-up on typing.
    func ensureModelLoaded() async {
        guard !isRemote, !isLoadingModel, let model = resolvedModel else { return }
        if loadedModel?.modelPath != model.modelPath { await loadModel(model) }
    }

    func autoLoadIfNeeded() async { await ensureModelLoaded() }

    /// Re-load the active model so changed settings (GPU, context length) take
    /// effect; the open conversation's history is replayed to restore context.
    func reloadCurrentModel() async {
        guard let model = loadedModel, !isLoadingModel else { return }
        genTask?.cancel()
        isGenerating = false
        await loadModel(model)
    }

    // MARK: Conversation switching

    func newConversation() async {
        genTask?.cancel()
        isGenerating = false
        currentConversationID = UUID()
        currentTitle = "New Chat"
        icon = "bubble.left.fill"
        pinnedModelPath = nil
        remoteEndpointID = nil
        contextStart = 0
        createdAt = Date()
        messages.removeAll()
        isFirstUserTurn = true
        setConfig(settings.defaultConfig, systemPrompt: nil)
        variableDefs = []
        variableScope = ""
        variableValues = [:]
        seedVariableDefaults()
        if isModelReady { try? await engine.reset(systemPrompt: systemBlock()) }
        updateUsage()
    }

    /// Start a fresh conversation pre-configured by a shortcut (system prompt,
    /// preferred model, generation config).
    func startShortcut(_ shortcut: Shortcut) async {
        genTask?.cancel()
        isGenerating = false
        currentConversationID = UUID()
        currentTitle = shortcut.name
        icon = shortcut.icon
        pinnedModelPath = shortcut.modelPath
        remoteEndpointID = nil
        contextStart = 0
        createdAt = Date()
        messages.removeAll()
        isFirstUserTurn = true
        setConfig(shortcut.config, systemPrompt: shortcut.systemPrompt)
        variableDefs = shortcut.variableDefs
        variableScope = shortcut.name
        variableValues = [:]
        seedVariableDefaults()
        // Lazy: only reset if the resolved model is already loaded; otherwise the
        // model loads on first type / send / the Load button.
        if isModelReady { try? await engine.reset(systemPrompt: systemBlock()) }
        updateUsage()
    }

    func selectConversation(_ id: UUID) async {
        guard id != currentConversationID, let convo = store.conversation(id: id) else { return }
        genTask?.cancel()
        isGenerating = false
        currentConversationID = convo.id
        currentTitle = convo.title
        icon = convo.icon ?? "bubble.left.fill"
        pinnedModelPath = convo.modelPath
        remoteEndpointID = convo.remoteEndpointId
        contextStart = 0
        createdAt = convo.createdAt
        setConfig(convo.config ?? .default, systemPrompt: convo.systemPrompt)
        variableDefs = convo.variableDefs ?? []
        variableScope = convo.variableScope ?? ""
        variableValues = convo.variables ?? [:]
        seedVariableDefaults()
        messages = convo.messages.map { ChatMessage(stored: $0) }
        // Lazy: replay only if the resolved model is already loaded; otherwise wait
        // for an explicit Load / first keystroke.
        if isModelReady { await replayHistory() } else { updateUsage() }
    }

    /// Apply edited per-chat settings (config, system prompt, icon, model).
    /// Only acts on the engine if a model is already loaded (otherwise lazy).
    func applyChatSettings(_ newConfig: GenConfig, systemPrompt: String?, icon: String, modelPath: String?,
                           name: String? = nil, variableDefs: [PromptVariableDef] = []) async {
        let contextChanged = newConfig.contextLength != config.contextLength
        let projectorChanged = (newConfig.loadProjector || newConfig.autoScreenshot) != (config.loadProjector || config.autoScreenshot)
        let systemChanged = systemPrompt != systemPromptOverride || variableDefs != self.variableDefs
        self.variableDefs = variableDefs
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { currentTitle = name }

        // The picker encodes a remote endpoint as "remote:<uuid>".
        if let sel = modelPath, sel.hasPrefix("remote:") {
            remoteEndpointID = String(sel.dropFirst("remote:".count))
            pinnedModelPath = nil
            if loadedModel != nil { unload() }   // free the local model; remote needs none
        } else {
            remoteEndpointID = nil
            pinnedModelPath = modelPath
        }
        setConfig(newConfig, systemPrompt: systemPrompt)
        seedVariableDefaults()   // a newly edited prompt may declare new variables
        self.icon = icon
        persistCurrent()

        guard !isRemote else { return }            // remote: nothing to load/replay
        guard loadedModel != nil else { return }   // lazy: nothing loaded yet
        if !isModelReady, let model = resolvedModel {
            await loadModel(model)             // model changed → load the new one
        } else if projectorChanged, let model = loadedModel {
            await loadModel(model)             // projector toggle → full reload
        } else if contextChanged {
            // Recreate just the context (no model disk reload). If the existing
            // KV cache migrates into the new window, no replay is needed at all.
            let preserved = (try? await engine.resizeContext(nCtx: config.contextLength)) ?? false
            if preserved && !systemChanged {
                updateUsage()
            } else {
                await replayHistory()
            }
        } else if systemChanged {
            await replayHistory()              // rebuild KV with the new system prompt
        }
    }

    func deleteConversation(_ id: UUID) async {
        store.delete(id: id)
        if id == currentConversationID {
            await newConversation()
        }
    }

    /// Reset the KV cache and re-evaluate the current conversation's completed
    /// turns so the model regains full context. No-op if no model is loaded.
    private func replayHistory(upTo endIndex: Int? = nil) async {
        guard engine.isLoaded else { updateUsage(); return }
        isReplaying = true
        try? await engine.reset(systemPrompt: systemBlock())
        isFirstUserTurn = true

        // Stateless chats never carry conversation context, so there is nothing
        // to replay — resetting the system prompt is enough.
        if config.discardContext {
            isReplaying = false
            updateUsage()
            return
        }

        if contextStart > messages.count { contextStart = 0 }
        // Iterate a snapshot: `messages` can be mutated on the main actor across the
        // `await`s below (a new send, a conversation switch, etc.), which would make
        // a live `messages[i]` go out of range.
        let msgs = messages
        let end = min(endIndex ?? msgs.count, msgs.count)
        var i = min(contextStart, msgs.count)
        while i < end {
            let m = msgs[i]
            if m.role == .user {
                let delta = userDelta(text: m.text, nMedia: m.attachments.count, first: isFirstUserTurn)
                try? await engine.evaluate(prompt: delta, imagePaths: m.imagePaths, audioPaths: m.audioPaths)
                isFirstUserTurn = false
                if i + 1 < end {
                    let a = msgs[i + 1]
                    if a.role == .assistant, !a.failed, !a.text.isEmpty {
                        try? await engine.evaluate(prompt: a.text, imagePaths: [], audioPaths: [])
                        i += 2
                        continue
                    }
                }
            }
            i += 1
        }
        isReplaying = false
        updateUsage()
    }

    /// Drop the oldest in-context turns (before the current/last user turn) to
    /// free room. Returns false if nothing more can be dropped.
    private func forceCompactStep() -> Bool {
        let lastUserIdx = messages.lastIndex { $0.role == .user } ?? messages.count
        guard contextStart < lastUserIdx else { return false }
        let remaining = lastUserIdx - contextStart
        var newStart = contextStart + max(2, remaining / 2)
        while newStart < lastUserIdx && messages[newStart].role != .user { newStart += 1 }
        if newStart > lastUserIdx { newStart = lastUserIdx }
        guard newStart > contextStart else { return false }
        contextStart = newStart
        return true
    }

    /// Recover from a "context is full" failure (a model that can't shift, e.g.
    /// a large image input): drop old turns, rebuild context up to the current
    /// turn, and retry the generation once.
    private func recoverContextFull(assistantID: UUID, text: String, attachments: [Attachment],
                                    images: [String], audio: [String], params: LMGenerationParams) async {
        guard forceCompactStep() else {
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[idx].isStreaming = false
                messages[idx].failed = true
                messages[idx].text = "⚠️ Context is full and couldn't be compressed further."
            }
            isGenerating = false; updateUsage(); persistCurrent()
            return
        }
        guard let aIdx = messages.firstIndex(where: { $0.id == assistantID }), aIdx > 0 else { return }
        await replayHistory(upTo: aIdx - 1)     // rebuild KV without the pending turn
        let delta = userDelta(text: text, nMedia: attachments.count, first: isFirstUserTurn)
        if !config.discardContext { isFirstUserTurn = false }
        // Retry once (no further recovery to avoid loops).
        await consume(engine.generate(prompt: delta, imagePaths: images, audioPaths: audio, params: params),
                      assistantID: assistantID)
    }

    /// When the context window is near full, drop the oldest in-context turns
    /// (still visible in the transcript) and replay. Works for any model,
    /// including M-RoPE ones that can't be position-shifted.
    func compactIfNeeded() async {
        guard isModelReady, !isGenerating, !isReplaying else { return }
        updateUsage()
        let (past, total) = contextUsage
        guard total > 0, past >= Int(Double(total) * 0.75) else { return }
        let remaining = messages.count - contextStart
        guard remaining > 2 else { return }              // one turn left — nothing to trim
        var newStart = contextStart + max(2, remaining / 2)
        while newStart < messages.count && messages[newStart].role != .user { newStart += 1 }
        guard newStart < messages.count else { return }
        contextStart = newStart
        await replayHistory()
    }

    // MARK: Sending

    func send(text: String, attachments: [Attachment]) {
        guard isModelReady, !isGenerating, !isReplaying else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let userMsg = ChatMessage(role: .user, text: trimmed, attachments: attachments)
        messages.append(userMsg)
        if currentTitle == "New Chat" { currentTitle = makeTitle(from: trimmed, attachments: attachments) }

        let assistantMsg = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistantMsg)
        let assistantID = assistantMsg.id

        isGenerating = true
        persistCurrent()   // save the user turn immediately

        if let endpoint = currentRemoteEndpoint {
            // ---- Remote (OpenAI-compatible) path ----
            let turns = remoteTurns()
            let cfg = config
            genTask = Task { [weak self] in
                await self?.consume(OpenAIClient.stream(endpoint: endpoint, turns: turns, config: cfg), assistantID: assistantID)
            }
        } else {
            // ---- Local llama.cpp path ----
            let stateless = config.discardContext
            let delta = userDelta(text: trimmed, nMedia: attachments.count, first: isFirstUserTurn || stateless)
            let images = attachments.filter { $0.kind == .image }.map { $0.url.path }
            let audio  = attachments.filter { $0.kind == .audio }.map { $0.url.path }
            let params = config.generationParams
            if !stateless { isFirstUserTurn = false }
            genTask = Task { [weak self] in
                guard let self else { return }
                if stateless { try? await self.engine.reset(systemPrompt: self.systemBlock()) }
                await self.consume(self.engine.generate(prompt: delta, imagePaths: images, audioPaths: audio, params: params),
                                   assistantID: assistantID,
                                   onContextFull: { [weak self] in
                                       await self?.recoverContextFull(assistantID: assistantID, text: trimmed,
                                                                      attachments: attachments, images: images,
                                                                      audio: audio, params: params)
                                   })
            }
        }
    }

    /// Drive an assistant message from a token stream (shared by local + remote).
    private func consume(_ stream: AsyncStream<GenerationEvent>, assistantID: UUID,
                         onContextFull: (() async -> Void)? = nil) async {
        var recover = false
        for await event in stream {
            guard let idx = messages.firstIndex(where: { $0.id == assistantID }) else { continue }
            switch event {
            case .token(let piece):
                messages[idx].text += piece
            case .done(let stats):
                messages[idx].isStreaming = false
                messages[idx].stats = stats
            case .failed(let msg):
                // Context overflow before any output → compact + retry once.
                if onContextFull != nil, messages[idx].text.isEmpty,
                   msg.localizedCaseInsensitiveContains("context is full") {
                    recover = true   // keep the message streaming; retry after the stream ends
                } else {
                    messages[idx].isStreaming = false
                    messages[idx].failed = true
                    if messages[idx].text.isEmpty { messages[idx].text = "⚠️ \(msg)" }
                    else { messages[idx].stats = "⚠️ \(msg)" }
                }
            }
        }
        if recover, let onContextFull {
            await onContextFull()   // re-runs generation via another consume, which finalizes state
            return
        }
        isGenerating = false
        updateUsage()
        persistCurrent()
    }

    /// Build the message list sent to a remote API from the transcript.
    private func remoteTurns() -> [ChatTurn] {
        var turns: [ChatTurn] = []
        let sys = resolvedSystemPrompt()
        if !sys.isEmpty { turns.append(ChatTurn(role: .system, text: sys)) }

        let history = messages.filter { !($0.role == .assistant && $0.isStreaming) }
        let relevant = config.discardContext ? Array(history.suffix(1)) : history
        for m in relevant {
            let role: ChatTurn.Role = m.role == .user ? .user : .assistant
            // Strip the model's <think> block from assistant history.
            let text = role == .assistant ? splitReasoning(m.text).answer : m.text
            turns.append(ChatTurn(role: role, text: text, imagePaths: m.imagePaths))
        }
        return turns
    }

    func stop() {
        if isRemote { genTask?.cancel() } else { engine.stop() }
    }

    // MARK: One-shot compose (keyboard round-trip)

    /// Generate a single answer for the openTihui keyboard, without touching the
    /// visible conversation. Uses the chat's endpoint if remote, otherwise loads
    /// the resolved on-device model. Restores the open chat's context afterwards.
    func composeGenerate(request: String, context: String, imagePaths: [String] = [],
                         config composeConfig: GenConfig? = nil, modelSelection: String? = nil,
                         onUpdate: @escaping (String) -> Void) async -> String {
        // Use the originating shortcut's config, else the app's default config.
        let cfg = composeConfig ?? settings.defaultConfig
        let userText = context.isEmpty ? request
            : (request.isEmpty ? context : "\(request)\n\n\"\"\"\n\(context)\n\"\"\"")
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imagePaths.isEmpty else { return "" }

        // Resolve the chosen model: nil → inherit the chat's current; "remote:<id>"
        // → that endpoint; otherwise a local model path.
        let endpoint: RemoteEndpoint? = {
            if let sel = modelSelection {
                return sel.hasPrefix("remote:") ? remotes.endpoints.first(where: { $0.selectionTag == sel }) : nil
            }
            return currentRemoteEndpoint
        }()
        let localModel: ManagedModel? = {
            if let sel = modelSelection, !sel.hasPrefix("remote:") {
                return models.models.first(where: { $0.modelPath == sel })
            }
            return modelSelection == nil ? resolvedModel : nil
        }()

        if let endpoint {
            var turns: [ChatTurn] = []
            let sys = resolvedSystemPrompt()
            if !sys.isEmpty { turns.append(ChatTurn(role: .system, text: sys)) }
            turns.append(ChatTurn(role: .user, text: userText, imagePaths: imagePaths))
            var full = ""
            for await ev in OpenAIClient.stream(endpoint: endpoint, turns: turns, config: cfg) {
                if case .token(let p) = ev { full += p; onUpdate(full) }
            }
            return full
        }

        guard let model = localModel else { return "" }
        // (Re)load the chosen model with the chosen context, forcing the projector
        // for images. Skip the reload when the right model/context is already up.
        let wantProjector = !imagePaths.isEmpty || cfg.loadProjector
        let needsReload = loadedModel?.modelPath != model.modelPath
            || contextUsage.total != cfg.contextLength
            || (!imagePaths.isEmpty && !(modelSnapshot?.supportsVision ?? false))
        if needsReload {
            await loadModel(model, contextLength: cfg.contextLength, projectorOverride: wantProjector)
        }
        guard loadedModel != nil else { return "" }
        try? await engine.reset(systemPrompt: systemBlock())
        let delta = userDelta(text: userText, nMedia: imagePaths.count, first: true, effort: cfg.thinkingEffort)
        var full = ""
        for await ev in engine.generate(prompt: delta, imagePaths: imagePaths, audioPaths: [], params: cfg.generationParams) {
            if case .token(let p) = ev { full += p; onUpdate(full) }
        }
        // Restore the open conversation: reload its model/context if compose used a
        // different one (loadModel replays history), else just rebuild the KV cache.
        if needsReload, let chatModel = resolvedModel {
            await loadModel(chatModel)
        } else {
            await replayHistory()
        }
        return full
    }

    // MARK: Persistence

    private func persistCurrent() {
        guard !messages.isEmpty else { return }
        let convo = Conversation(id: currentConversationID,
                                 title: currentTitle,
                                 createdAt: createdAt,
                                 updatedAt: Date(),
                                 modelID: loadedModel?.id,
                                 modelName: loadedModel?.name,
                                 systemPrompt: systemPromptOverride,
                                 modelPath: pinnedModelPath,
                                 remoteEndpointId: remoteEndpointID,
                                 config: config,
                                 icon: icon,
                                 variables: variableValues.isEmpty ? nil : variableValues,
                                 variableDefs: variableDefs.isEmpty ? nil : variableDefs,
                                 variableScope: variableScope.isEmpty ? nil : variableScope,
                                 messages: messages.filter { !$0.isStreaming || !$0.text.isEmpty }.map { $0.stored })
        store.upsert(convo)
    }

    private func updateUsage() { contextUsage = engine.contextUsage }

    private func makeTitle(from text: String, attachments: [Attachment]) -> String {
        let base = text.isEmpty ? (attachments.isEmpty ? "New Chat" : "Image chat") : text
        let oneLine = base.replacingOccurrences(of: "\n", with: " ")
        return String(oneLine.prefix(48))
    }

    // MARK: ChatML formatting

    /// Prompt dialect, derived from the GGUF's built-in chat template.
    /// ChatML (Qwen-style) is the default; Gemma models use turn tags and fold
    /// the system prompt into the first user turn (no system role).
    private enum PromptFormat { case chatml, gemma }
    private var promptFormat: PromptFormat {
        (modelSnapshot?.chatTemplate.contains("<start_of_turn>") ?? false) ? .gemma : .chatml
    }

    private func systemBlock() -> String {
        let sys = resolvedSystemPrompt()
        guard !sys.isEmpty else { return "" }
        switch promptFormat {
        case .chatml: return "<|im_start|>system\n\(sys)<|im_end|>\n"
        case .gemma:  return ""   // merged into the first user turn by userDelta
        }
    }

    /// `effort` overrides the chat config's thinking effort (compose runs use
    /// their own per-run config — the prefill must match its generation params).
    private func userDelta(text: String, nMedia: Int, first: Bool, effort: ThinkingEffort? = nil) -> String {
        let marker = engine.mediaMarker
        let markers = String(repeating: "\(marker)\n", count: nMedia)
        switch promptFormat {
        case .chatml:
            // When reasoning is off, prefill an empty <think> block so the model
            // skips thinking (matches Qwen3's enable_thinking=false template).
            let assistantOpen = (effort ?? config.thinkingEffort).enabled
                ? "<|im_start|>assistant\n"
                : "<|im_start|>assistant\n<think>\n\n</think>\n\n"
            let userBlock = "<|im_start|>user\n\(markers)\(text)<|im_end|>\n" + assistantOpen
            // Close the previous assistant turn (its <|im_end|> was not decoded).
            return first ? userBlock : "<|im_end|>\n\(userBlock)"
        case .gemma:
            // Gemma has no system role — fold the system prompt into the first
            // user turn. <end_of_turn> is the model's EOG token.
            let sys = resolvedSystemPrompt()
            let sysPrefix = (first && !sys.isEmpty) ? "\(sys)\n\n" : ""
            let userBlock = "<start_of_turn>user\n\(sysPrefix)\(markers)\(text)<end_of_turn>\n<start_of_turn>model\n"
            return first ? userBlock : "<end_of_turn>\n\(userBlock)"
        }
    }
}
