//
//  KeyboardSetup.swift
//  openTihui
//
//  The openTihui keyboard's quick actions are the user's Shortcuts, handed over
//  as a base64-encoded JSON payload. Primary channel: the shared App Group
//  container (auto-sync — see KeyboardSync). Fallback: the same payload copied
//  to the clipboard ("Copy setup" → import in the keyboard), which keeps builds
//  without the App Group entitlement fully working.
//

import Foundation

struct KBActionPayload: Codable, Hashable {
    var title: String
    var icon: String
    var instruction: String   // the shortcut's system prompt
    var useClipboard: Bool = false
    var useScreenshot: Bool = false
}

struct KBSetupPayload: Codable {
    var actions: [KBActionPayload] = []
    /// The app's current language (e.g. "zh-Hans"), so the keyboard — which
    /// otherwise follows the system language — can match the app's UI language.
    var lang: String = "en"

    static let prefix = "opentihui-setup:"

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return KBSetupPayload.prefix }
        return KBSetupPayload.prefix + data.base64EncodedString()
    }

    static func decode(_ s: String?) -> KBSetupPayload? {
        guard let s, s.hasPrefix(prefix),
              let data = Data(base64Encoded: String(s.dropFirst(prefix.count))),
              let payload = try? JSONDecoder().decode(KBSetupPayload.self, from: data)
        else { return nil }
        return payload
    }
}

/// Pushes the keyboard's configuration (and generated results) into the shared
/// App Group container so the keyboard picks them up automatically — no
/// copy/paste needed. Every write is best-effort: on builds without the App
/// Group entitlement the writes silently do nothing and the clipboard flow
/// remains the transport.
enum KeyboardSync {
    /// Shared defaults, or nil when no App Group is configured for this build.
    static var sharedDefaults: UserDefaults? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !id.isEmpty, id.hasPrefix("group.") else { return nil }
        return UserDefaults(suiteName: id)
    }

    /// The payload the keyboard should show, from the current shortcut list +
    /// the user's keyboard selection (same rules as KeyboardSettingsView).
    static func payload(shortcuts: [Shortcut]) -> KBSetupPayload {
        let kb = shortcuts.filter { $0.allowInKeyboard }
        let ids = AppSettings.shared.keyboardShortcutIDs
        let selected = ids.isEmpty ? kb : ids.compactMap { id in kb.first { $0.id.uuidString == id } }
        let actions = selected.map {
            KBActionPayload(title: $0.name, icon: $0.icon, instruction: $0.systemPrompt,
                            useClipboard: $0.config.autoClipboard, useScreenshot: $0.config.autoScreenshot)
        }
        return KBSetupPayload(actions: actions,
                              lang: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// Write the current keyboard setup to the shared container.
    static func push(shortcuts: [Shortcut]) {
        sharedDefaults?.set(payload(shortcuts: shortcuts).encoded(), forKey: "kb.payload")
    }

    /// Hand a generated result to the keyboard ("Paste" inserts it without
    /// touching the clipboard). One-shot on the keyboard side.
    static func publishResult(_ text: String) {
        guard let d = sharedDefaults else { return }
        d.set(text, forKey: "kb.result")
        d.set(Date().timeIntervalSince1970, forKey: "kb.resultAt")
    }
}
