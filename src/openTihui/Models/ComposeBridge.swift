//
//  ComposeBridge.swift
//  openTihui
//
//  Receives a writing task handed over from the openTihui keyboard extension via
//  the `opentihui://compose` URL scheme, and surfaces it to the UI.
//

import SwiftUI

struct ComposeRequest: Identifiable {
    let id = UUID()
    var context: String         // the text the user had in the host field
    var instruction: String?    // the shortcut's instruction, handed over directly
    var shortcutName: String?   // name of the source shortcut (resolved live in-app)
    var useClipboard = false     // use the clipboard as context
    var useScreenshot = false    // attach a recent screenshot as context
}

@MainActor
final class ComposeBridge: ObservableObject {
    @Published var request: ComposeRequest?

    func handle(_ url: URL) {
        guard url.scheme == "opentihui", url.host == "compose" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        let ctx = value("ctx") ?? ""
        var instruction: String?
        if let b64 = value("instr"), let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) {
            instruction = s
        }
        request = ComposeRequest(context: ctx,
                                 instruction: instruction,
                                 shortcutName: value("name"),
                                 useClipboard: value("clip") == "1",
                                 useScreenshot: value("shot") == "1")
    }
}
