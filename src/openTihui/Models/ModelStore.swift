//
//  ModelStore.swift
//  openTihui
//
//  Tracks the GGUF models available to the app: ones imported into the app's
//  Documents directory, plus any developer "test" models discovered on disk.
//

import Foundation
import Combine

struct ManagedModel: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var modelPath: String
    var mmprojPath: String?          // optional multimodal projector
    var isBuiltIn: Bool = false      // discovered, not imported by the user

    var hasMultimodal: Bool { mmprojPath != nil }

    var fileSizeText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modelExists: Bool { FileManager.default.fileExists(atPath: modelPath) }

    /// File name on disk (never changed by renaming the display name).
    var fileName: String { URL(fileURLWithPath: modelPath).lastPathComponent }

    /// Containing folder relative to the Models directory — disambiguates
    /// same-named models that live in different folders.
    var folderLabel: String {
        let root = ModelStore.modelsDirectory.path
        let dir = URL(fileURLWithPath: modelPath).deletingLastPathComponent().path
        if dir == root { return "Models" }
        if dir.hasPrefix(root + "/") { return String(dir.dropFirst(root.count + 1)) }
        return dir
    }

    /// Full path shown to the user, relative to the app's Documents folder.
    var displayPath: String { ModelStore.appRelativePath(modelPath) }
}

final class ModelStore: ObservableObject {
    @Published private(set) var models: [ManagedModel] = []

    private let noneSentinel = ""
    private let fm = FileManager.default

    // Imported-model registry + projector choices, stored as JSON in
    // Documents/Config (visible in the Files app).
    private struct ModelsConfig: Codable {
        var imported: [ManagedModel] = []
        var projectorOverrides: [String: String] = [:]   // [modelPath: mmproj path or "" for none]
        var nameOverrides: [String: String] = [:]         // [modelPath: user-chosen display name]

        init() {}
        // Tolerant decoding so adding a key doesn't discard an existing config.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            imported = try c.decodeIfPresent([ManagedModel].self, forKey: .imported) ?? []
            projectorOverrides = try c.decodeIfPresent([String: String].self, forKey: .projectorOverrides) ?? [:]
            nameOverrides = try c.decodeIfPresent([String: String].self, forKey: .nameOverrides) ?? [:]
        }
    }
    private static let configURL = LocalStore.fileURL("models.json")

    static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `path` made relative to the app's Documents folder — the sandbox prefix
    /// (`/…/Application/<id>/Documents/`) is stripped, so users see e.g.
    /// `Models/Repo/model.gguf` instead of an opaque container path.
    static func appRelativePath(_ path: String) -> String {
        func deprivate(_ s: String) -> String { s.hasPrefix("/private") ? String(s.dropFirst(8)) : s }
        let p = deprivate(path)
        let docs = deprivate(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)
        if p.hasPrefix(docs + "/") { return String(p.dropFirst(docs.count + 1)) }
        return p
    }

    init() {
        _ = ModelStore.modelsDirectory   // ensure the folder exists so it shows up in the Files app
        reload()
    }

    /// Synchronous reload (use on the main thread / when callers need the result
    /// immediately, e.g. after a user action).
    func reload() {
        models = computeModels()
    }

    /// Reload without blocking the caller: the directory scan / config reads run
    /// on a background queue and `models` is published back on the main thread.
    /// Used for view `onAppear` (Settings) so opening the screen never stalls.
    func reloadInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.computeModels()
            DispatchQueue.main.async { self.models = result }
        }
    }

    /// The (disk-bound) work: discover test models, imported models, dropped-in
    /// GGUFs, and apply projector overrides. Safe to run off the main thread —
    /// it only does file I/O and never touches `@Published` state.
    private func computeModels() -> [ManagedModel] {
        var result = discoverTestModels()
        result.append(contentsOf: loadImported())
        // Surface any GGUF files the user dropped into the Models folder via the
        // Files app that aren't already tracked.
        let known = Set(result.map { $0.modelPath })
        for m in scanModelsDirectory() where !known.contains(m.modelPath) {
            result.append(m)
        }
        // Apply per-model projector (mmproj) + display-name overrides.
        let cfg = readConfig()
        for i in result.indices {
            if let choice = cfg.projectorOverrides[result[i].modelPath] {
                result[i].mmprojPath = choice == noneSentinel ? nil : (fm.fileExists(atPath: choice) ? choice : result[i].mmprojPath)
            }
            if let custom = cfg.nameOverrides[result[i].modelPath], !custom.isEmpty {
                result[i].name = custom
            }
        }
        return result
    }

    /// Set (or clear, with nil/empty) a user-chosen display name for a model.
    /// Only the UI name changes — the file on disk is untouched.
    func setName(_ name: String?, for model: ManagedModel) {
        var cfg = readConfig()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { cfg.nameOverrides[model.modelPath] = trimmed }
        else { cfg.nameOverrides.removeValue(forKey: model.modelPath) }
        writeConfig(cfg)
        reload()
    }

    // MARK: Multimodal projector (mmproj) selection

    /// All projector (`mmproj-*.gguf`) files available to pair with a model:
    /// those in the Models folder plus any alongside discovered test models.
    func availableProjectors() -> [URL] {
        // Projectors anywhere under the Models folder (recursing repo subfolders)…
        var urls = allGGUFs(in: ModelStore.modelsDirectory)
            .filter { $0.lastPathComponent.lowercased().contains("mmproj") }
        // …plus any sitting next to a currently-known model (e.g. the test snapshot dir).
        for m in models {
            let dir = URL(fileURLWithPath: m.modelPath).deletingLastPathComponent()
            if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                urls += entries.filter { $0.pathExtension.lowercased() == "gguf" && $0.lastPathComponent.lowercased().contains("mmproj") }
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// Choose the projector for a model. Pass nil to use no projector (text-only).
    func setProjector(_ path: String?, for model: ManagedModel) {
        var cfg = readConfig()
        cfg.projectorOverrides[model.modelPath] = path ?? noneSentinel
        writeConfig(cfg)
        reload()
    }

    private func readConfig() -> ModelsConfig {
        if let data = try? Data(contentsOf: ModelStore.configURL),
           let cfg = try? JSONDecoder().decode(ModelsConfig.self, from: data) {
            return cfg
        }
        // Migrate from the previous UserDefaults storage (first launch only).
        var cfg = ModelsConfig()
        if let data = UserDefaults.standard.data(forKey: "importedModels"),
           let list = try? JSONDecoder().decode([ManagedModel].self, from: data) {
            cfg.imported = list
        }
        cfg.projectorOverrides = UserDefaults.standard.dictionary(forKey: "projectorOverrides") as? [String: String] ?? [:]
        writeConfig(cfg)
        return cfg
    }

    private func writeConfig(_ cfg: ModelsConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(cfg) { try? data.write(to: ModelStore.configURL, options: .atomic) }
    }

    /// Recursively scan the app's Models directory (including Hugging Face repo
    /// subfolders) for `.gguf` files and pair vision projectors with their model
    /// within the same folder.
    private func scanModelsDirectory() -> [ManagedModel] {
        let ggufs = allGGUFs(in: ModelStore.modelsDirectory)
        // Pair within each containing folder (so different repos don't cross-pair).
        let byFolder = Dictionary(grouping: ggufs) { $0.deletingLastPathComponent().path }

        var result: [ManagedModel] = []
        for (_, group) in byFolder {
            let projectors = group.filter { $0.lastPathComponent.lowercased().contains("mmproj") }
            let mainModels = group.filter { !$0.lastPathComponent.lowercased().contains("mmproj") }

            func projector(for model: URL) -> URL? {
                if projectors.count == 1 { return projectors.first }
                let stem = model.deletingPathExtension().lastPathComponent.lowercased()
                return projectors.max { a, b in
                    sharedPrefix(stem, a.lastPathComponent.lowercased()) < sharedPrefix(stem, b.lastPathComponent.lowercased())
                }
            }
            for url in mainModels {
                result.append(ManagedModel(name: url.deletingPathExtension().lastPathComponent,
                                           modelPath: url.path,
                                           mmprojPath: projector(for: url)?.path,
                                           isBuiltIn: false))
            }
        }
        return result
    }

    /// All `.gguf` files under a directory, recursing into subfolders.
    private func allGGUFs(in dir: URL) -> [URL] {
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "gguf" { out.append(url) }
        return out
    }

    private func sharedPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) { if x == y { n += 1 } else { break } }
        return n
    }

    // MARK: Imported models (persisted)

    private func loadImported() -> [ManagedModel] {
        readConfig().imported.filter { $0.modelExists }
    }

    private func saveImported(_ list: [ManagedModel]) {
        var cfg = readConfig()
        cfg.imported = list
        writeConfig(cfg)
    }

    /// Copy a picked GGUF (and optional mmproj) into the app sandbox and register it.
    func importModel(modelURL: URL, mmprojURL: URL?) throws {
        let destModel = ModelStore.modelsDirectory.appendingPathComponent(modelURL.lastPathComponent)
        try copyItem(at: modelURL, to: destModel)

        var destMmproj: URL?
        if let mmprojURL {
            let d = ModelStore.modelsDirectory.appendingPathComponent(mmprojURL.lastPathComponent)
            try copyItem(at: mmprojURL, to: d)
            destMmproj = d
        }

        let model = ManagedModel(name: modelURL.deletingPathExtension().lastPathComponent,
                                 modelPath: destModel.path,
                                 mmprojPath: destMmproj?.path,
                                 isBuiltIn: false)
        var imported = loadImported()
        imported.removeAll { $0.modelPath == model.modelPath }
        imported.append(model)
        saveImported(imported)
        reload()
    }

    /// Register files that already live inside the app sandbox (e.g. downloaded
    /// directly by `ModelDownloader`).
    func registerLocalModel(name: String, modelPath: String, mmprojPath: String?) {
        let model = ManagedModel(name: name, modelPath: modelPath, mmprojPath: mmprojPath, isBuiltIn: false)
        var imported = loadImported()
        imported.removeAll { $0.modelPath == modelPath }
        imported.append(model)
        saveImported(imported)
        reload()
    }

    func delete(_ model: ManagedModel) {
        guard !model.isBuiltIn else { return }
        try? fm.removeItem(atPath: model.modelPath)
        if let mm = model.mmprojPath { try? fm.removeItem(atPath: mm) }
        var imported = loadImported()
        imported.removeAll { $0.id == model.id }
        saveImported(imported)
        reload()
    }

    private func copyItem(at src: URL, to dest: URL) throws {
        let didAccess = src.startAccessingSecurityScopedResource()
        defer { if didAccess { src.stopAccessingSecurityScopedResource() } }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
    }

    // MARK: Built-in / developer test models

    /// Look for the Qwen3-VL test model referenced in the project task. Present
    /// only on a developer Mac running the Simulator; silently ignored otherwise.
    private func discoverTestModels() -> [ManagedModel] {
        // On the Simulator the host Mac's home is exposed via SIMULATOR_HOST_HOME,
        // which lets us reach the cached test GGUF on the developer machine.
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return [] }
        let base = "\(home)/.cache/huggingface/hub/models--Qwen--Qwen3-VL-2B-Instruct-GGUF/snapshots/52d6c8ffea26cc873ac5ad116f8631268d7eb503"
        let model = "\(base)/Qwen3VL-2B-Instruct-Q4_K_M.gguf"
        let mmproj = "\(base)/mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf"
        guard fm.fileExists(atPath: model) else { return [] }
        return [ManagedModel(name: "Qwen3-VL 2B Instruct (test)",
                             modelPath: model,
                             mmprojPath: fm.fileExists(atPath: mmproj) ? mmproj : nil,
                             isBuiltIn: true)]
    }
}
