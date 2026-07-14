//
//  DownloadManager.swift
//  openTihui
//
//  App-wide manager for GGUF downloads. Downloads keep running while you browse
//  away from the download sheet; progress and cancel are available anywhere
//  (the Models tab "Downloads" section).
//

import Foundation
import Combine

struct DownloadItem: Identifiable {
    enum State: Equatable { case downloading, finished, failed(String) }
    let id = UUID()
    var filename: String
    var progress: Double = 0
    var bytesText: String = ""
    var state: State = .downloading
    var taskID: Int
}

final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    private var session: URLSession!
    private weak var store: ModelStore?

    private let lock = NSLock()
    private var destByTask: [Int: URL] = [:]
    private var moveByTask: [Int: Result<URL, Error>] = [:]

    var active: [DownloadItem] { items.filter { $0.state == .downloading } }
    var hasActive: Bool { !active.isEmpty }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Download a GGUF into the Models folder; the store rescans (and pairs
    /// model + mmproj) when it finishes.
    @MainActor
    func enqueue(url: URL, store: ModelStore, token: String? = nil) {
        self.store = store
        let dest = Self.destination(for: url)
        // Skip if the same file is already downloading (by destination path).
        lock.lock(); let dup = destByTask.values.contains(dest); lock.unlock()
        if dup { return }

        var req = URLRequest(url: url)
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = session.downloadTask(with: req)

        lock.lock(); destByTask[task.taskIdentifier] = dest; lock.unlock()
        items.append(DownloadItem(filename: Self.relativeName(dest), taskID: task.taskIdentifier))
        task.resume()
    }

    @MainActor
    func cancel(_ item: DownloadItem) {
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == item.taskID }?.cancel() }
        items.removeAll { $0.id == item.id }
    }

    @MainActor
    func clearFinished() {
        items.removeAll { $0.state != .downloading }
    }

    static let recommendedName = "Qwen3.5 0.8B (vision)"

    /// Enqueue the recommended starter model + its vision projector.
    @MainActor
    func enqueueRecommended(store: ModelStore) {
        enqueue(recommended: RecommendedModel.catalog[0], store: store)
    }

    /// Enqueue a curated model (weights + its multimodal projector).
    @MainActor
    func enqueue(recommended m: RecommendedModel, store: ModelStore) {
        let base = "https://huggingface.co/\(m.repo)/resolve/main/"
        if let w = URL(string: base + m.file) { enqueue(url: w, store: store) }
        if let mmproj = m.mmproj, let p = URL(string: base + mmproj) { enqueue(url: p, store: store) }
    }

    static func filename(for url: URL) -> String {
        var f = url.lastPathComponent
        if f.isEmpty || !f.lowercased().hasSuffix(".gguf") {
            f = f.isEmpty ? "model-\(UUID().uuidString).gguf" : f + ".gguf"
        }
        return f
    }

    /// Destination inside the Models folder, mirroring the Hugging Face repo
    /// layout (Models/<owner>/<repo>/<path…>) so model + projector + shards stay
    /// grouped. Non-HF URLs are saved flat by filename.
    static func destination(for url: URL) -> URL {
        let base = ModelStore.modelsDirectory
        let comps = url.pathComponents   // ["/", owner, repo, "resolve", branch, file…]
        if (url.host ?? "").contains("huggingface.co"),
           let r = comps.firstIndex(of: "resolve"), r >= 3, comps.count > r + 2 {
            var dest = base.appendingPathComponent(comps[r - 2], isDirectory: true)   // owner
                           .appendingPathComponent(comps[r - 1], isDirectory: true)   // repo
            for part in comps[(r + 2)...] { dest.appendPathComponent(part) }          // file path (skips branch)
            return dest
        }
        return base.appendingPathComponent(filename(for: url))
    }

    /// Path of a destination relative to the Models folder, for display.
    static func relativeName(_ dest: URL) -> String {
        let base = ModelStore.modelsDirectory.path
        if dest.path.hasPrefix(base + "/") { return String(dest.path.dropFirst(base.count + 1)) }
        return dest.lastPathComponent
    }

    private func updateMain(taskID: Int, _ change: @escaping (inout DownloadItem) -> Void) {
        DispatchQueue.main.async {
            if let i = self.items.firstIndex(where: { $0.taskID == taskID }) { change(&self.items[i]) }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let frac = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let w = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
        let t = totalBytesExpectedToWrite > 0 ? ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file) : "?"
        updateMain(taskID: downloadTask.taskIdentifier) { $0.progress = frac; $0.bytesText = "\(w) / \(t)" }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tid = downloadTask.taskIdentifier
        lock.lock(); let dest = destByTask[tid]; lock.unlock()
        guard let dest else { return }
        let result: Result<URL, Error>
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            result = .success(dest)
        } catch {
            result = .failure(error)
        }
        lock.lock(); moveByTask[tid] = result; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        lock.lock(); let moved = moveByTask[tid]; moveByTask[tid] = nil; destByTask[tid] = nil; lock.unlock()

        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.taskID == tid }) else { return }
            if let error {
                if (error as? URLError)?.code == .cancelled { self.items.removeAll { $0.taskID == tid } }
                else { self.items[idx].state = .failed(error.localizedDescription) }
            } else if case .success = moved {
                self.items[idx].state = .finished
                self.items[idx].progress = 1
                self.store?.reload()
            } else if case .failure(let e) = moved {
                self.items[idx].state = .failed(e.localizedDescription)
            }
        }
    }
}

/// A curated, known-good on-device model: one tap downloads the weights and the
/// matching multimodal projector from the Hugging Face repo (no in-app browser).
struct RecommendedModel: Identifiable {
    var name: String
    var detail: String        // capabilities / quant summary (localized key)
    var repo: String          // Hugging Face repo (owner/name)
    var file: String          // weights filename in the repo
    var mmproj: String?       // projector filename, if multimodal
    var id: String { repo + "/" + file }

    static let catalog: [RecommendedModel] = [
        RecommendedModel(name: "Qwen3.5 0.8B",
                         detail: "Tiny and fast · vision · Q4_K_XL",
                         repo: "unsloth/Qwen3.5-0.8B-GGUF",
                         file: "Qwen3.5-0.8B-UD-Q4_K_XL.gguf",
                         mmproj: "mmproj-BF16.gguf"),
        RecommendedModel(name: "Qwen3.5 2B",
                         detail: "Better quality · vision · Q4_K_XL",
                         repo: "unsloth/Qwen3.5-2B-GGUF",
                         file: "Qwen3.5-2B-UD-Q4_K_XL.gguf",
                         mmproj: "mmproj-BF16.gguf"),
        RecommendedModel(name: "Gemma 4 E2B (mobile)",
                         detail: "Google Gemma, QAT for phones · vision + audio",
                         repo: "unsloth/gemma-4-E2B-it-qat-mobile-GGUF",
                         file: "gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
                         mmproj: "mmproj-BF16.gguf"),
        RecommendedModel(name: "Gemma 4 E4B (mobile)",
                         detail: "Larger Gemma, QAT for phones · vision + audio",
                         repo: "unsloth/gemma-4-E4B-it-qat-mobile-GGUF",
                         file: "gemma-4-E4B-it-qat-UD-Q2_K_XL.gguf",
                         mmproj: "mmproj-BF16.gguf"),
    ]
}
