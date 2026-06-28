//
//  KeyboardAI.swift
//  openTihui Keyboard
//
//  The keyboard is a launcher: it shows the user's Shortcuts as chips and hands
//  the task to the app for generation (no in-keyboard inference). This file just
//  holds the chip config, imported from the app via the clipboard setup payload
//  and stored in the extension's own UserDefaults (no App Group).
//

import Foundation

/// A keyboard quick action — mirrors a openTihui Shortcut.
struct KBAction: Codable, Equatable, Identifiable {
    var title: String
    var icon: String
    var instruction: String
    var useClipboard: Bool = false
    var useScreenshot: Bool = false
    var id: String { title + "\u{1}" + instruction }
}

private struct KBPayload: Codable {
    var actions: [KBAction] = []
    var lang: String = ""
}

struct KBConfig: Equatable {
    var actions: [KBAction] = []
    /// App's UI language (e.g. "zh-Hans"); empty = follow the system language.
    var lang: String = ""

    static func load() -> KBConfig {
        let d = UserDefaults.standard
        var actions: [KBAction] = []
        if let s = d.string(forKey: "kb.actionsJSON"), let data = s.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([KBAction].self, from: data) {
            actions = decoded
        }
        return KBConfig(actions: actions, lang: d.string(forKey: "kb.lang") ?? "")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(lang, forKey: "kb.lang")
        if let data = try? JSONEncoder().encode(actions), let s = String(data: data, encoding: .utf8) {
            d.set(s, forKey: "kb.actionsJSON")
        }
    }

    /// Parse the base64-JSON setup payload copied from the app.
    static func parse(_ s: String?) -> KBConfig? {
        let prefix = "opentihui-setup:"
        guard let s, s.hasPrefix(prefix),
              let data = Data(base64Encoded: String(s.dropFirst(prefix.count))),
              let p = try? JSONDecoder().decode(KBPayload.self, from: data),
              !p.actions.isEmpty
        else { return nil }
        return KBConfig(actions: p.actions, lang: p.lang)
    }
}
