//
//  Shortcut.swift
//  openTihui
//
//  A "shortcut" bundles a system prompt + preferred model (+ thinking effort)
//  for a recurring task (translation, image recognition, …). Running one starts
//  a pre-configured chat; the configuration is stored in that conversation.
//

import Foundation
import Combine

/// File envelope for exporting/importing a single shortcut as JSON.
struct ShortcutExport: Codable {
    static let marker = "opentihui.shortcut"
    var format: String = ShortcutExport.marker
    var version: Int = 1
    var shortcut: Shortcut
}

struct Shortcut: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var icon: String                 // SF Symbol name
    var systemPrompt: String
    var modelPath: String?           // preferred model (nil = use whatever is loaded)
    var config: GenConfig = .default // context + sampling + reasoning (incl. auto-context)
    /// Whether this shortcut can appear as a chip in the openTihui keyboard.
    var allowInKeyboard: Bool = true
    /// Variables referenced as `$name` in the system prompt (name + options).
    var variableDefs: [PromptVariableDef] = []
}

extension Shortcut {
    // Tolerant decoding for forward/backward compatibility.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Shortcut",
                  icon: try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles",
                  systemPrompt: try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        config = try c.decodeIfPresent(GenConfig.self, forKey: .config) ?? .default
        allowInKeyboard = try c.decodeIfPresent(Bool.self, forKey: .allowInKeyboard) ?? true
        variableDefs = try c.decodeIfPresent([PromptVariableDef].self, forKey: .variableDefs) ?? []
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var shortcuts: [Shortcut] = []

    private let fileURL = LocalStore.fileURL("shortcuts.json")
    private let seededKey = "shortcutsSeeded"

    init() {
        load()
        if !UserDefaults.standard.bool(forKey: seededKey) {
            shortcuts = Shortcut.defaults
            persist()
            UserDefaults.standard.set(true, forKey: seededKey)
        }
    }

    func upsert(_ shortcut: Shortcut) {
        if let idx = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[idx] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        persist()
    }

    func delete(_ shortcut: Shortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        persist()
    }

    /// Replace all shortcuts with the built-in defaults.
    func resetToDefaults() {
        shortcuts = Shortcut.defaults
        persist()
    }

    func delete(at offsets: IndexSet) {
        shortcuts.remove(atOffsets: offsets)
        persist()
    }

    // MARK: Export / import (.json file)

    /// JSON data for a single shortcut, wrapped with a format marker so we can
    /// recognise our files on import.
    func exportData(_ shortcut: Shortcut) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try? encoder.encode(ShortcutExport(shortcut: shortcut))
    }

    /// Import a shortcut from a `.json` file opened with the app. Returns the
    /// imported shortcut, or nil if the file isn't a openTihui shortcut.
    @discardableResult
    func importFromFile(_ url: URL) -> Shortcut? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(ShortcutExport.self, from: data),
              export.format == ShortcutExport.marker,
              !export.shortcut.systemPrompt.isEmpty || !export.shortcut.name.isEmpty
        else { return nil }
        var s = export.shortcut
        s.id = UUID()                              // fresh id so it doesn't clobber an existing one
        upsert(s)
        return s
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Shortcut].self, from: data)
        else { shortcuts = []; return }
        shortcuts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            try? data.write(to: fileURL, options: .atomic)
        }
        KeyboardSync.push(shortcuts: shortcuts)   // keep the keyboard's chips in sync
    }
}

extension Shortcut {
    /// Built-in starter shortcuts seeded on first launch. All are stateless
    /// (one-shot tasks that don't need conversation memory).
    private static var statelessConfig: GenConfig {
        var c = GenConfig.default
        c.discardContext = true
        c.thinkingEffort = .off
        c.loadProjector = false     // text shortcuts don't need the vision projector
        c.autoScreenshot = false    // …and shouldn't pull in screenshots (keeps them text-only)
        return c
    }

    static var defaults: [Shortcut] {
        [
            Shortcut(name: String(localized: "Polite"), icon: "face.smiling",
                     systemPrompt: String(localized: "Rewrite the user's message to be warmer and more polite, keeping the meaning. Output only the rewritten text."),
                     modelPath: nil, config: statelessConfig),
            Shortcut(name: String(localized: "Shorter"), icon: "scissors",
                     systemPrompt: String(localized: "Make the user's message shorter and clearer, keeping the meaning. Output only the rewritten text."),
                     modelPath: nil, config: statelessConfig),
            Shortcut(name: String(localized: "Fix Grammar"), icon: "checkmark.seal",
                     systemPrompt: String(localized: "Fix the spelling and grammar of the user's message. Output only the corrected text."),
                     modelPath: nil, config: statelessConfig),
            Shortcut(name: String(localized: "Reply"), icon: "arrowshape.turn.up.left",
                     systemPrompt: String(localized: "Write a reply to the user's message. Output only the reply."),
                     modelPath: nil, config: statelessConfig),
            Shortcut(name: String(localized: "Translator"), icon: "globe",
                     systemPrompt: String(localized: "Translate the user's message from $from into $into. Output only the translation, with no extra commentary."),
                     modelPath: nil, config: statelessConfig,
                     variableDefs: [
                        PromptVariableDef(name: "from", options: ["Auto-detect", "English", "Chinese", "Spanish", "French", "German", "Japanese", "Korean", "Italian", "Portuguese", "Russian", "Arabic"]),
                        PromptVariableDef(name: "into", options: ["English", "Chinese", "Spanish", "French", "German", "Japanese", "Korean", "Italian", "Portuguese", "Russian", "Arabic"]),
                     ]),
            Shortcut(name: String(localized: "Summarizer"), icon: "list.bullet.rectangle",
                     systemPrompt: String(localized: "Summarize the user's text into a few clear bullet points capturing the key information. Do not add opinions."),
                     modelPath: nil, config: statelessConfig),
            Shortcut(name: String(localized: "Image Recognition"), icon: "photo.on.rectangle.angled",
                     systemPrompt: String(localized: "Carefully describe the image the user sends: identify the main objects, any visible text, and the overall scene. Be concise and factual."),
                     modelPath: nil,
                     config: { var c = statelessConfig; c.contextLength = 8192; c.loadProjector = true; c.autoScreenshot = true; return c }(),
                     allowInKeyboard: false),
        ]
    }

    static let iconChoices = [
        "sparkles", "globe", "photo.on.rectangle.angled", "list.bullet.rectangle",
        "chevron.left.forwardslash.chevron.right", "text.bubble", "doc.text.magnifyingglass",
        "character.book.closed", "brain.head.profile", "wand.and.stars", "envelope", "graduationcap",
        "bubble.left.fill", "star.fill", "heart.fill", "bolt.fill", "lightbulb.fill", "flame.fill",
        "leaf.fill", "pencil", "camera.fill", "music.note", "cart.fill", "airplane",
        "function", "terminal.fill", "newspaper.fill", "quote.bubble.fill", "person.fill", "gamecontroller.fill"
    ]
}
