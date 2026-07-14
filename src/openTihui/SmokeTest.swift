//
//  SmokeTest.swift
//  openTihui
//
//  End-to-end self-test of the inference pipeline, gated behind the
//  LLAMACHAT_SMOKETEST environment variable so it never runs for normal users.
//  Launch from the Simulator with:
//    SIMCTL_CHILD_LLAMACHAT_SMOKETEST=1 xcrun simctl launch --console-pty …
//

import UIKit

enum SmokeTest {
    private static var mode: String? { ProcessInfo.processInfo.environment["LLAMACHAT_SMOKETEST"] }
    static var isEnabled: Bool { ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13"].contains(mode ?? "") }

    static func run() {
        Task.detached(priority: .userInitiated) {
            switch mode {
            case "2": await runDownloadTest()
            case "3": await listModels()
            case "4": await runConversationTest()
            case "5": await runAutoloadTest()
            case "6": await runThinkingTest()
            case "7": await runShortcutTest()
            case "8": await runCompactionTest()
            case "9": await runFeatureTest()
            case "10": await runResizeTest()
            case "11": await runMissingFileTest()
            case "12": await runRemoteTest()
            case "13": await runPDFExportTest()
            default:  await runAsync()
            }
            NSLog("SMOKETEST: done")
        }
    }

    /// Verify the OpenAI-compatible remote path against a local mock server
    /// (URL from REMOTE_URL env, e.g. http://127.0.0.1:8088/v1).
    @MainActor
    private static func runRemoteTest() async {
        let urlStr = ProcessInfo.processInfo.environment["REMOTE_URL"] ?? "http://127.0.0.1:8088/v1"
        let remotes = RemoteStore()
        let ep = RemoteEndpoint(name: "Mock", baseURL: urlStr, apiKey: "test", modelID: "mock", supportsVision: false)
        remotes.upsert(ep)
        let chat = ChatViewModel(engine: InferenceEngine(), store: ConversationStore(), models: ModelStore(), remotes: remotes, settings: AppSettings.shared)
        await chat.newConversation()
        await chat.applyChatSettings(GenConfig.default, systemPrompt: nil, icon: "cloud", modelPath: ep.selectionTag)
        log("isRemote=\(chat.isRemote) ready=\(chat.isModelReady) name=\(chat.resolvedModelName)")
        await send(chat, "hi")
        let ans = chat.messages.last?.text ?? ""
        log("remote answer: \(ans)")
        log("remote OK (expect Hello world): \(ans.lowercased().contains("hello") && ans.lowercased().contains("world"))")
    }

    /// Verify loading a model whose file is gone fails gracefully (no crash).
    @MainActor
    private static func runMissingFileTest() async {
        let models = ModelStore()
        let chat = ChatViewModel(engine: InferenceEngine(), store: ConversationStore(), models: models, remotes: RemoteStore(), settings: AppSettings.shared)
        let ghost = ManagedModel(name: "Ghost", modelPath: "/tmp/missing-\(UUID().uuidString).gguf", mmprojPath: nil)
        log("ghost.modelExists=\(ghost.modelExists)")
        await chat.loadModel(ghost)
        log("after load-missing: error=\(chat.loadError ?? "nil")")
        log("after load-missing: loaded=\(chat.loadedModel != nil) (expect false)")
        log("SURVIVED missing-file load")
    }

    /// Verify context resize: window updates, model stays loaded, history preserved.
    @MainActor
    private static func runResizeTest() async {
        let models = ModelStore()
        guard let model = models.models.first(where: { $0.isBuiltIn }) ?? models.models.first else {
            log("FAIL: no model"); return
        }
        let chat = ChatViewModel(engine: InferenceEngine(), store: ConversationStore(), models: models, remotes: RemoteStore(), settings: AppSettings.shared)
        var cfg = GenConfig.default; cfg.contextLength = 2048; cfg.maxTokens = 24; cfg.thinkingEffort = .off
        await chat.startShortcut(Shortcut(name: "Resize", icon: "x", systemPrompt: "You are helpful.", modelPath: model.modelPath, config: cfg))
        await chat.ensureModelLoaded()
        await send(chat, "Remember this codeword: ORCHID.")
        log("before resize: total=\(chat.contextUsage.total)")

        var bigger = cfg; bigger.contextLength = 4096
        await chat.applyChatSettings(bigger, systemPrompt: chat.systemPromptOverride, icon: chat.icon, modelPath: chat.pinnedModelPath)
        log("after resize: total=\(chat.contextUsage.total) loaded=\(chat.loadedModel != nil)")

        await send(chat, "What was the codeword? One word.")
        let ans = (chat.messages.last?.text ?? "").lowercased()
        log("recall after resize (expect orchid): \(ans.contains("orchid")) | ans=\(ans.prefix(30))")
    }

    /// Verify the "load projector" toggle and stateless (discard-context) mode.
    @MainActor
    private static func runFeatureTest() async {
        let models = ModelStore()
        guard let model = models.models.first(where: { $0.isBuiltIn }) ?? models.models.first else {
            log("FAIL: no model"); return
        }
        let chat = ChatViewModel(engine: InferenceEngine(), store: ConversationStore(), models: models, remotes: RemoteStore(), settings: AppSettings.shared)

        // mmproj off -> vision must be unavailable
        var noProj = GenConfig.default; noProj.loadProjector = false; noProj.maxTokens = 20; noProj.thinkingEffort = .off
        await chat.startShortcut(Shortcut(name: "NoProj", icon: "x", systemPrompt: "You are helpful.", modelPath: model.modelPath, config: noProj))
        await chat.ensureModelLoaded()
        log("projector OFF -> vision=\(chat.supportsVision) (expect false)")

        // stateless -> context must not grow across turns
        var stateless = GenConfig.default; stateless.loadProjector = false; stateless.discardContext = true
        stateless.maxTokens = 24; stateless.thinkingEffort = .off
        await chat.startShortcut(Shortcut(name: "Stateless", icon: "x", systemPrompt: "You are helpful. Answer in one short sentence.", modelPath: model.modelPath, config: stateless))
        await chat.ensureModelLoaded()
        var pasts: [Int] = []
        for k in 0..<3 {
            await send(chat, "Give a one-sentence fun fact number \(k + 1).")
            pasts.append(chat.contextUsage.past)
            log("stateless turn \(k): past=\(chat.contextUsage.past) msgs=\(chat.messages.count)")
        }
        let grew = (pasts.last ?? 0) > (pasts.first ?? 0) + 40
        log("stateless context bounded: \(!grew) (pasts=\(pasts))")
    }

    /// Overflow a small-context multimodal chat (incl. an image) to verify the
    /// M-RoPE context-shift crash is fixed and auto-compaction kicks in.
    @MainActor
    private static func runCompactionTest() async {
        let models = ModelStore()
        guard let model = models.models.first(where: { $0.isBuiltIn }) ?? models.models.first else {
            log("FAIL: no model"); return
        }
        let chat = ChatViewModel(engine: InferenceEngine(), store: ConversationStore(), models: models, remotes: RemoteStore(), settings: AppSettings.shared)
        var cfg = GenConfig.default; cfg.contextLength = 1024; cfg.maxTokens = 120; cfg.thinkingEffort = .off
        let sc = Shortcut(name: "Compact", icon: "bolt", systemPrompt: "You are a helpful assistant. Answer in a few sentences.",
                          modelPath: model.modelPath, config: cfg)
        await chat.startShortcut(sc)
        await chat.ensureModelLoaded()
        log("loaded ctx=\(chat.contextUsage.total) vision=\(chat.supportsVision)")

        for k in 0..<8 {
            await chat.compactIfNeeded()
            await send(chat, "Tell me one interesting fact about the number \(k + 1), in two sentences.")
            log("turn \(k): ctx=\(chat.contextUsage.past)/\(chat.contextUsage.total) msgs=\(chat.messages.count)")
        }

        if chat.supportsVision, let img = makeTestImage() {
            await chat.compactIfNeeded()
            chat.send(text: "What is the dominant color of this image?", attachments: [Attachment(kind: .image, url: img)])
            for _ in 0..<120 { if !chat.isGenerating && !chat.isReplaying { break }; try? await Task.sleep(nanoseconds: 1_000_000_000) }
            log("IMAGE turn: ctx=\(chat.contextUsage.past)/\(chat.contextUsage.total) ans=\(chat.messages.last?.text.prefix(40) ?? "")")
        }
        log("SURVIVED — no crash; final ctx=\(chat.contextUsage.past)/\(chat.contextUsage.total)")
    }

    /// Verify a shortcut applies its system prompt + config and persists them.
    @MainActor
    private static func runShortcutTest() async {
        let models = ModelStore()
        guard let model = models.models.first(where: { $0.isBuiltIn }) ?? models.models.first else {
            log("FAIL: no model"); return
        }
        let convos = ConversationStore()
        let chat = ChatViewModel(engine: InferenceEngine(), store: convos, models: models, remotes: RemoteStore(), settings: AppSettings.shared)
        await chat.loadModel(model)

        var cfg = GenConfig.default; cfg.maxTokens = 40; cfg.thinkingEffort = .off
        let shortcut = Shortcut(name: "FR Translator", icon: "globe",
                                systemPrompt: "You are a translation engine. Translate the user's message into French. Output only the French translation.",
                                modelPath: model.modelPath, config: cfg)
        await chat.startShortcut(shortcut)
        log("shortcut started: title=\(chat.currentTitle) effort=\(chat.thinkingEffort.label) ctx=\(chat.config.contextLength)")
        log("active override: \(chat.systemPromptOverride?.prefix(35) ?? "nil")")

        await send(chat, "Good morning, my friend.")
        let ans = chat.messages.last?.text ?? ""
        log("shortcut answer: \(ans.prefix(60))")
        let fr = ["bonjour", "bon matin", "ami", "matin"].contains { ans.lowercased().contains($0) }
        log("system prompt applied (expect French): \(fr)")

        let c = convos.conversations.first
        log("persisted systemPrompt set: \(c?.systemPrompt != nil) | configMaxTokens: \(c?.config?.maxTokens ?? -1)")
    }

    /// Verify thinking on/off via the chat template prefill.
    @MainActor
    private static func runThinkingTest() async {
        let models = ModelStore()
        guard let model = models.models.first(where: { $0.isBuiltIn }) ?? models.models.first else {
            log("FAIL: no model"); return
        }
        let settings = AppSettings.shared
        let chat = ChatViewModel(engine: InferenceEngine(), store: ConversationStore(), models: models, remotes: RemoteStore(), settings: settings)
        await chat.loadModel(model)

        for effort in [ThinkingEffort.high, .low, .off] {
            await chat.newConversation()
            chat.thinkingEffort = effort
            // The tiny test model doesn't open <think> on its own — for the Low
            // case, instruct it to, so the budget force-close path is exercised.
            let prompt = effort == .low
                ? "Begin your reply with the exact text \"<think>\" and then reason step by step in great detail, sentence after sentence, about 17 * 23 without ever concluding."
                : "What is 17 * 23? Think very carefully step by step about every detail before answering."
            await send(chat, prompt)
            let t = chat.messages.last?.text ?? ""
            let split = splitReasoning(t)
            log("effort=\(effort.label) hasThinkTag=\(t.contains("<think>")) thinkClosed=\(t.contains("</think>")) thinkLen=\(split.thinking?.count ?? -1) answerLen=\(split.answer.count)")
            log("  answer=\(split.answer.prefix(70))")
        }

        // Parser self-check for models that DO emit <think> blocks.
        let done = splitReasoning("<think>Let me compute 2+2.</think>\n\nThe answer is 4.")
        log("parse(done): thinking=\(done.thinking ?? "nil") | answer=\(done.answer) | live=\(done.isThinking)")
        let live = splitReasoning("<think>Still working on it")
        log("parse(live): thinking=\(live.thinking ?? "nil") | answer='\(live.answer)' | live=\(live.isThinking)")
        let plain = splitReasoning("Just a normal answer.")
        log("parse(plain): thinking=\(plain.thinking ?? "nil") | answer=\(plain.answer) | live=\(plain.isThinking)")
    }

    /// Verify last-model auto-load (fix: remember + auto-load) and mmproj selection.
    @MainActor
    private static func runAutoloadTest() async {
        let models = ModelStore()
        let settings = AppSettings.shared
        let chat = ChatViewModel(engine: InferenceEngine(), store: ConversationStore(), models: models, remotes: RemoteStore(), settings: settings)

        guard let model = models.models.first(where: { $0.isBuiltIn }) ?? models.models.first else {
            log("FAIL: no model"); return
        }
        let projs = models.availableProjectors()
        log("available projectors: \(projs.map { $0.lastPathComponent })")

        settings.lastModelPath = model.modelPath
        log("candidate=\(chat.resolvedModel?.name ?? "nil") loadedBefore=\(chat.loadedModel != nil)")

        await chat.autoLoadIfNeeded()
        log("autoload -> loaded=\(chat.loadedModel?.name ?? "nil") backend=\(chat.modelInfo?.backend ?? "?")")

        models.setProjector(nil, for: model)
        let none = models.models.first { $0.modelPath == model.modelPath }
        log("setProjector(none) -> multimodal=\(none?.hasMultimodal ?? true)")

        if let p = projs.first {
            models.setProjector(p.path, for: model)
            let set = models.models.first { $0.modelPath == model.modelPath }
            log("setProjector(\(p.lastPathComponent)) -> mmprojSet=\(set?.mmprojPath != nil)")
        }
    }

    /// Verify multi-conversation switching preserves per-chat context (fix #1).
    @MainActor
    private static func runConversationTest() async {
        let store = ModelStore()
        guard let model = store.models.first(where: { $0.isBuiltIn }) ?? store.models.first else {
            log("FAIL: no model"); return
        }
        let convos = ConversationStore()
        let settings = AppSettings.shared
        let chat = ChatViewModel(engine: InferenceEngine(), store: convos, models: store, remotes: RemoteStore(), settings: settings)

        await chat.loadModel(model)
        log("loaded \(model.name)")

        // Chat A
        await chat.newConversation()
        let aID = chat.currentConversationID
        await send(chat, "My favorite color is teal. Just acknowledge.")
        log("A title: \(chat.currentTitle)")

        // Chat B
        await chat.newConversation()
        await send(chat, "My favorite color is crimson. Just acknowledge.")

        // Switch back to A and ask — should recall teal, not crimson.
        await chat.selectConversation(aID)
        log("switched back, replayed \(chat.messages.count) msgs")
        await send(chat, "What is my favorite color? Answer with one word.")
        let answer = (chat.messages.last?.text ?? "").lowercased()
        log("A recall (expect teal): \(answer)")
        log("context preserved: \(answer.contains("teal"))")
        log("conversations persisted: \(convos.conversations.count)")
    }

    @MainActor
    private static func send(_ chat: ChatViewModel, _ text: String) async {
        chat.send(text: text, attachments: [])
        for _ in 0..<90 {
            if !chat.isGenerating && !chat.isReplaying { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// List the models the store discovers (verifies Files-folder scanning).
    private static func listModels() async {
        let store = await ModelStore()
        let models = await MainActor.run { store.models }
        log("found \(models.count) model(s)")
        for m in models {
            log("• \(m.name) | mmproj=\(m.mmprojPath != nil) | builtIn=\(m.isBuiltIn) | \(m.modelPath)")
        }
    }

    /// Exercise the URL-download → register → load → generate pipeline.
    private static func runDownloadTest() async {
        guard let urlStr = ProcessInfo.processInfo.environment["DL_MODEL_URL"],
              let url = URL(string: urlStr) else {
            log("FAIL: DL_MODEL_URL not set")
            return
        }
        let store = await ModelStore()
        let manager = await DownloadManager()
        let want = DownloadManager.filename(for: url)
        log("downloading from \(url.absoluteString)")

        await MainActor.run { manager.enqueue(url: url, store: store) }
        // wait up to 180s for completion
        for _ in 0..<180 {
            let state = await MainActor.run { manager.items.first?.state }
            if state == .finished { break }
            if case .failed(let m)? = state { log("FAIL download: \(m)"); return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let model = await MainActor.run(body: {
            store.models.first { URL(fileURLWithPath: $0.modelPath).lastPathComponent == want }
        }) else {
            log("FAIL: downloaded model not registered")
            return
        }
        log("downloaded + registered: \(model.fileSizeText) at \(model.modelPath)")

        let settings = AppSettings.shared
        var dlCfg = GenConfig.default; dlCfg.maxTokens = 24
        let engine = InferenceEngine()
        do {
            try await engine.load(model: model, contextLength: dlCfg.contextLength, gpuEnabled: settings.gpuEnabled)
            log("DL load OK: \(engine.modelInfo()?.desc ?? "?")")
            try await engine.reset(systemPrompt: "")
            var out = ""
            for await ev in engine.generate(prompt: "Once upon a time", imagePaths: [], audioPaths: [], params: dlCfg.generationParams) {
                if case .token(let t) = ev { out += t }
                if case .done(let s) = ev { log("DL gen done: \(s)") }
                if case .failed(let m) = ev { log("DL gen FAIL: \(m)") }
            }
            log("DL output: \(out.prefix(120))")
        } catch {
            log("FAIL DL load: \(error.localizedDescription)")
        }
    }

    private static func log(_ s: String) { NSLog("SMOKETEST: %@", s) }

    private static func runAsync() async {
        let store = ModelStore()
        guard let model = store.models.first(where: { $0.isBuiltIn }) ?? store.models.first else {
            log("FAIL: no model discovered (is SIMULATOR_HOST_HOME set / cache present?)")
            return
        }
        log("model: \(model.name) multimodal=\(model.hasMultimodal)")

        let settings = AppSettings.shared
        var cfg = GenConfig.default; cfg.maxTokens = 64
        if ProcessInfo.processInfo.environment["FORCE_GPU"] == "1" { settings.gpuEnabled = true }
        log("gpuOffloadSupported=\(LlamaBridge.gpuOffloadSupported()) gpuEnabledSetting=\(settings.gpuEnabled)")
        let engine = InferenceEngine()

        do {
            try await engine.load(model: model, contextLength: cfg.contextLength, gpuEnabled: settings.gpuEnabled)
            log("load OK")
        } catch {
            log("FAIL load: \(error.localizedDescription)")
            return
        }

        let info = engine.modelInfo()
        log("info desc=\(info?.desc ?? "?") vision=\(info?.supportsVision ?? false) audio=\(info?.supportsAudio ?? false) backend=\(info?.backend ?? "?") usingGPU=\(info?.usingGPU ?? false)")

        // ---- Text generation ----
        do {
            try await engine.reset(systemPrompt: "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n")
            let prompt = "<|im_start|>user\nIn one short sentence, what is the capital of France?<|im_end|>\n<|im_start|>assistant\n"
            var out = ""
            let p = cfg.generationParams
            for await ev in engine.generate(prompt: prompt, imagePaths: [], audioPaths: [], params: p) {
                switch ev {
                case .token(let t): out += t
                case .done(let s): log("TEXT done: \(s)")
                case .failed(let m): log("TEXT FAIL: \(m)")
                }
            }
            log("TEXT output: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch { log("TEXT FAIL reset: \(error)") }

        // ---- Image (vision) generation ----
        if engine.modelInfo()?.supportsVision == true, let imgURL = makeTestImage() {
            do {
                try await engine.reset(systemPrompt: "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n")
                let marker = engine.mediaMarker
                let prompt = "<|im_start|>user\n\(marker)\nWhat is the dominant color of this image? Answer with one word.<|im_end|>\n<|im_start|>assistant\n"
                var out = ""
                let p = cfg.generationParams
                for await ev in engine.generate(prompt: prompt, imagePaths: [imgURL.path], audioPaths: [], params: p) {
                    switch ev {
                    case .token(let t): out += t
                    case .done(let s): log("IMAGE done: \(s)")
                    case .failed(let m): log("IMAGE FAIL: \(m)")
                    }
                }
                log("IMAGE output: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch { log("IMAGE FAIL reset: \(error)") }
        }
    }

    /// Render a solid red square with a known color for the vision test.
    /// Verify a PDF can be rendered OFF the main thread (so export can show a
    /// live progress UI without freezing the app).
    private static func runPDFExportTest() async {
        var msgs: [ChatMessage] = []
        msgs.append(ChatMessage(role: .user, text: "Describe this image and tell me a story about the number 42."))
        if let img = await MainActor.run(body: { makeTestImage() }) {
            msgs.append(ChatMessage(role: .user, text: "Here is an image.", attachments: [Attachment(kind: .image, url: img)]))
        }
        msgs.append(ChatMessage(role: .assistant,
                                text: "<think>thinking</think>The image is mostly red. " + String(repeating: "Lorem ipsum dolor sit amet. ", count: 400)))
        // This function already runs off the main actor (Task.detached in run()),
        // so this verifies the whole Core Text render is off-main safe.
        let data = ChatExporter.pdfData(title: "Test Export", subtitle: "smoke · now", messages: msgs)
        let isPDF = data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46])   // "%PDF"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-export.pdf")
        try? data.write(to: url)
        log("PDF off-main: bytes=\(data.count) header=\(isPDF ? "%PDF" : "BAD") at=\(url.path)")
    }

    private static func makeTestImage() -> URL? {
        let size = CGSize(width: 224, height: 224)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = img.jpegData(compressionQuality: 0.95) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-red.jpg")
        try? data.write(to: url)
        return url
    }
}
