//
//  AppSettings.swift
//  openTihui
//
//  Global / device-level settings, persisted as JSON in Documents/Config
//  (visible in the Files app). Per-chat tuning (context, sampling, reasoning)
//  lives in `GenConfig` on each conversation instead.
//

import Foundation
import Combine

/// Reasoning ("thinking") effort, à la llama-server's reasoning budget. Off
/// disables the `<think>` block entirely; Low/Medium cap it; High is unlimited.
enum ThinkingEffort: Int, CaseIterable, Identifiable {
    case off = 0, low, medium, high
    var id: Int { rawValue }
    var label: String { ["Off", "Low", "Medium", "High"][rawValue] }
    var enabled: Bool { self != .off }
    /// Max reasoning tokens before force-closing `</think>`; 0 = unlimited.
    var budget: Int {
        switch self {
        case .off:    return 0
        case .low:    return 256
        case .medium: return 1024
        case .high:   return 0
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var gpuEnabled: Bool { didSet { save() } }
    @Published var systemPrompt: String { didSet { save() } }

    /// Default generation settings for new (non-shortcut) chats and the keyboard's
    /// generic "Generate in app". Tunable in Settings.
    @Published var defaultConfig: GenConfig { didSet { save() } }

    /// Whether this device's GPU can run Metal (resolved off-main shortly after
    /// launch). `nil` until the probe finishes — not persisted. Drives the
    /// Settings status line without ever blocking the UI on the probe.
    @Published var gpuSupported: Bool?

    /// Path of the most recently loaded model, used for auto-loading on demand.
    @Published var lastModelPath: String? { didSet { save() } }
    /// User-chosen default model for new chats.
    @Published var defaultModelPath: String? { didSet { save() } }

    /// IDs of the Shortcuts shown as chips in the openTihui keyboard (empty =
    /// use the first few shortcuts by default).
    @Published var keyboardShortcutIDs: [String] { didSet { save() } }

    /// Last value the user chose for each prompt `$variable` (by name), so the
    /// next chat / compose defaults to their previous choice.
    @Published var lastVariableValues: [String: String] { didSet { save() } }

    private struct Snapshot: Codable {
        var gpuEnabled: Bool
        var systemPrompt: String
        var lastModelPath: String?
        var defaultModelPath: String?
        var keyboardShortcutIDs: [String]
        var lastVariableValues: [String: String]
        var defaultConfig: GenConfig?   // optional → tolerant of older files
    }

    private static let fileURL = LocalStore.fileURL("settings.json")
    private var loaded = false

    private init() {
        #if targetEnvironment(simulator)
        let gpuDefault = false   // Metal in the iOS Simulator is unreliable for ggml.
        #else
        let gpuDefault = true
        #endif

        if let data = try? Data(contentsOf: Self.fileURL),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            gpuEnabled = s.gpuEnabled
            systemPrompt = s.systemPrompt
            lastModelPath = s.lastModelPath
            defaultModelPath = s.defaultModelPath
            keyboardShortcutIDs = s.keyboardShortcutIDs
            lastVariableValues = s.lastVariableValues
            defaultConfig = s.defaultConfig ?? .default
        } else {
            // Migrate from the previous UserDefaults storage (first launch only).
            let d = UserDefaults.standard
            gpuEnabled = d.object(forKey: "gpuEnabled") == nil ? gpuDefault : d.bool(forKey: "gpuEnabled")
            systemPrompt = d.string(forKey: "systemPrompt") ?? "You are a helpful, concise assistant."
            lastModelPath = d.string(forKey: "lastModelPath")
            defaultModelPath = d.string(forKey: "defaultModelPath")
            keyboardShortcutIDs = d.stringArray(forKey: "keyboardShortcutIDs") ?? []
            lastVariableValues = (d.dictionary(forKey: "lastVariableValues") as? [String: String]) ?? [:]
            defaultConfig = .default
        }
        // The default system prompt follows the app's language (so the model
        // replies in it). Applies to new installs and any install still on the
        // untouched English default; custom prompts are left alone.
        if systemPrompt == "You are a helpful, concise assistant." {
            systemPrompt = String(localized: "You are a helpful, concise assistant.")
        }
        loaded = true
        save()   // ensure the JSON file exists (writes the migrated values)
    }

    private func save() {
        guard loaded else { return }
        let snapshot = Snapshot(gpuEnabled: gpuEnabled, systemPrompt: systemPrompt,
                                lastModelPath: lastModelPath, defaultModelPath: defaultModelPath,
                                keyboardShortcutIDs: keyboardShortcutIDs, lastVariableValues: lastVariableValues,
                                defaultConfig: defaultConfig)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
