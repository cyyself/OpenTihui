//
//  KeyboardSetup.swift
//  openTihui
//
//  The openTihui keyboard's quick actions are the user's Shortcuts. Since the
//  keyboard extension can't read the app's stores (no App Group), the chosen
//  shortcuts + the inline endpoint are handed over as a base64-encoded JSON
//  payload on the clipboard. The keyboard has matching decode types.
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
