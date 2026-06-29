//
//  KeyboardRootView.swift
//  openTihui Keyboard
//
//  A launcher keyboard: it shows your Shortcuts as chips and hands the text
//  before the cursor to the openTihui app to generate (where you can tune
//  options, pick a model, etc.). The app copies the result back, and "Insert
//  result" drops it in.
//

import SwiftUI
import UIKit

struct KeyboardRootView: View {
    let actions: KeyboardActions

    @State private var config = KBConfig.load()
    @State private var status: Status = .idle

    private enum Status: Equatable { case idle, imported, error(String) }

    /// Fallback chips before the user imports their shortcut selection.
    private static let defaultActions: [KBAction] = [
        .init(title: "Polite", icon: "face.smiling", instruction: "Rewrite this to be warmer and more polite, keeping the meaning. Return only the rewritten text."),
        .init(title: "Shorter", icon: "scissors", instruction: "Make this shorter and clearer, keeping the meaning. Return only the rewritten text."),
        .init(title: "Fix", icon: "checkmark.seal", instruction: "Fix the spelling and grammar. Return only the corrected text."),
        .init(title: "Reply", icon: "arrowshape.turn.up.left", instruction: "Write a reply to this message. Return only the reply."),
    ]

    /// Match the app's UI language (the keyboard otherwise follows the system).
    private var locale: Locale { config.lang.isEmpty ? .autoupdatingCurrent : Locale(identifier: config.lang) }

    private var presets: [KBAction] { config.actions.isEmpty ? Self.defaultActions : config.actions }

    var body: some View {
        VStack(spacing: 8) {
            header
            if !actions.hasFullAccess() {
                fullAccessNotice
            } else {
                actionChips
                bottomRow
                statusLine
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280)   // taller: shortcuts wrap into a vertical grid
        .background(Color(.systemGray6))
        .environment(\.locale, locale)
        .task { autoImportIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Native keyboard switcher (always shown): tap = next keyboard,
            // long-press = the keyboard picker, so you can jump back to your own.
            SwitchKeyboardButton(configure: actions.configureSwitchButton)
                .frame(width: 38, height: 34)
            Label("openTihui", systemImage: "sparkles").font(.subheadline.weight(.semibold))
            Spacer()
            Button { actions.deleteContextBefore() } label: {
                Text("Clear").font(.caption.weight(.medium))
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            keyButton("delete.left") { actions.deleteBackward() }
        }
    }

    private var actionChips: some View {
        ScrollView(.vertical, showsIndicators: false) {
            FlowLayout(spacing: 8) {
                ForEach(presets) { action in
                    Button { openApp(action) } label: {
                        Label { Text(LocalizedStringKey(action.title)) }
                            icon: { Image(systemName: action.icon) }
                            .font(.callout).fixedSize()          // chip hugs its text — no truncation
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Color(.systemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Button { openApp(nil) } label: {
                Label("Generate in app", systemImage: "arrow.up.forward.app")
                    .font(.callout).frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button { insertClipboard() } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .font(.callout).frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            if config.actions.isEmpty {
                VStack(spacing: 5) {
                    Text("Showing default actions. In the app: Settings ▸ openTihui Keyboard ▸ Copy setup.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { importConfig() } label: {
                        Label("Import shortcuts from app", systemImage: "square.and.arrow.down")
                    }
                    .font(.caption).buttonStyle(.borderedProminent).controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Text("Tap a shortcut → generate in app → Insert result.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { importConfig() } label: { Label("Re-import", systemImage: "arrow.triangle.2.circlepath") }
                        .font(.caption2)
                }
            }
        case .imported:
            Label("Loaded \(config.actions.count) shortcuts", systemImage: "checkmark.circle")
                .font(.caption2).foregroundStyle(.green)
        case .error(let m):
            Text(m).font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var fullAccessNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.secondary)
            Text("Turn on “Allow Full Access”")
                .font(.subheadline.weight(.semibold))
            Text("Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ openTihui — needed to load your shortcuts and insert results.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if actions.needsInputModeSwitchKey() {
                Button { actions.advanceToNextInputMode() } label: {
                    Label("Switch keyboard", systemImage: "globe")
                }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
    }

    // MARK: actions

    private func keyButton(_ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.body)
                .frame(width: 38, height: 34)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Hand the text before the cursor (and the chosen shortcut) to the app.
    /// The text to act on: the host's selection if any, else the text before the cursor.
    private var hostText: String {
        let selected = actions.selectedText()
        return selected.isEmpty ? actions.contextBefore() : selected
    }

    private func openApp(_ action: KBAction?) {
        var comps = URLComponents()
        comps.scheme = "opentihui"
        comps.host = "compose"
        var items = [URLQueryItem(name: "ctx", value: hostText)]
        if let action {
            items.append(URLQueryItem(name: "name", value: action.title))
            if let data = action.instruction.data(using: .utf8) {
                items.append(URLQueryItem(name: "instr", value: data.base64EncodedString()))
            }
            if action.useClipboard { items.append(URLQueryItem(name: "clip", value: "1")) }
            if action.useScreenshot { items.append(URLQueryItem(name: "shot", value: "1")) }
        }
        comps.queryItems = items
        if let url = comps.url { actions.openApp(url) }
    }

    private func insertClipboard() {
        // Importing the keyboard setup takes priority if it's on the clipboard.
        if let cfg = KBConfig.parse(actions.clipboard()) { cfg.save(); config = cfg; status = .imported; return }
        guard let text = actions.clipboard(), !text.isEmpty else {
            status = .error("Nothing to insert. Generate in the app first, then come back.")
            return
        }
        actions.insert(text)
        status = .idle
    }

    private func importConfig() {
        if let cfg = KBConfig.parse(actions.clipboard()) {
            cfg.save(); config = cfg; status = .imported
        } else {
            status = .error("In the app: Settings ▸ openTihui Keyboard ▸ Copy setup, then tap here.")
        }
    }

    /// On first appearance (before any shortcuts are imported), pick up a setup
    /// payload sitting on the clipboard from the app's "Copy setup" action.
    private func autoImportIfNeeded() {
        guard config.actions.isEmpty, actions.hasFullAccess() else { return }
        if let cfg = KBConfig.parse(actions.clipboard()) {
            cfg.save(); config = cfg; status = .imported
        }
    }
}

/// Wraps content-sized chips into rows (left to right, top to bottom), so each
/// chip keeps its natural width — no truncation. Scrolls vertically when tall.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {   // wrap to next row
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A UIKit button wired to the system keyboard switcher (tap = next keyboard,
/// long-press = the keyboard picker). Styled to match the keyboard's keys.
private struct SwitchKeyboardButton: UIViewRepresentable {
    let configure: (UIButton) -> Void

    func makeUIView(context: Context) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "globe"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .systemBackground
        b.layer.cornerRadius = 8
        b.setContentHuggingPriority(.required, for: .horizontal)
        configure(b)
        return b
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
