//
//  KeyboardViewController.swift
//  openTihui Keyboard
//
//  Hosts the SwiftUI keyboard UI and bridges it to the text document proxy,
//  full-access state, the next-keyboard switch, and opening the containing app.
//

import UIKit
import SwiftUI

/// Closures the SwiftUI keyboard uses to act on the host text field and system.
struct KeyboardActions {
    var insert: (String) -> Void
    var deleteBackward: () -> Void
    var deleteContextBefore: () -> Void
    var contextBefore: () -> String
    var contextAfter: () -> String
    var selectedText: () -> String
    var clipboard: () -> String?
    var hasFullAccess: () -> Bool
    var openApp: (URL) -> Void
    var advanceToNextInputMode: () -> Void
    var needsInputModeSwitchKey: () -> Bool
}

final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let actions = KeyboardActions(
            insert: { [weak self] in self?.textDocumentProxy.insertText($0) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            deleteContextBefore: { [weak self] in
                guard let self else { return }
                let n = (self.textDocumentProxy.documentContextBeforeInput ?? "").count
                for _ in 0..<n { self.textDocumentProxy.deleteBackward() }
            },
            contextBefore: { [weak self] in self?.textDocumentProxy.documentContextBeforeInput ?? "" },
            contextAfter: { [weak self] in self?.textDocumentProxy.documentContextAfterInput ?? "" },
            selectedText: { [weak self] in self?.textDocumentProxy.selectedText ?? "" },
            clipboard: { [weak self] in (self?.hasFullAccess ?? false) ? UIPasteboard.general.string : nil },
            hasFullAccess: { [weak self] in self?.hasFullAccess ?? false },
            openApp: { [weak self] in self?.openAppURL($0) },
            advanceToNextInputMode: { [weak self] in self?.advanceToNextInputMode() },
            needsInputModeSwitchKey: { [weak self] in self?.needsInputModeSwitchKey ?? true }
        )

        let root = KeyboardRootView(actions: actions)
        let host = UIHostingController(rootView: root)
        self.host = host
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Open the containing app by walking the responder chain to UIApplication —
    /// the supported way to launch from a keyboard extension.
    private func openAppURL(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
    }
}
