//
//  KeyboardRootView.swift
//  openTihui Keyboard
//
//  A typing keyboard (English letters + numbers/symbols layers) with an AI
//  panel: swipe up (or tap ✨) to show your Shortcuts as chips and hand the
//  text before the cursor to the openTihui app to generate. The app copies the
//  result back, and "Paste" drops it in. Typing works without Full Access.
//

import SwiftUI
import UIKit

struct KeyboardRootView: View {
    let actions: KeyboardActions

    @State private var config = KBConfig.load()
    @State private var status: Status = .idle

    // Typing state
    @State private var showActions = false          // false = keys, true = AI panel
    @State private var layer: KeyLayer = .letters
    @State private var shifted = false
    @State private var capsLock = false
    @State private var lastShiftTap = Date.distantPast

    private enum Status: Equatable { case idle, imported, error(String) }
    private enum KeyLayer { case letters, numbers, symbols }

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
            if showActions {
                actionsPanel
            } else {
                typingPad
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 280, alignment: .top)   // pin header — no shift when switching modes
        .background(Color(.systemGray6))
        .environment(\.locale, locale)
        .task { autoImportIfNeeded() }
    }

    /// Shortcut chips + hand-off actions, revealed by swiping up on the keys
    /// (or tapping ✨). Swipe down (or tap ⌨) to get back to typing.
    private var actionsPanel: some View {
        VStack(spacing: 8) {
            actionChips
            bottomRow
            if actions.hasFullAccess() {
                statusLine
            } else {
                Text("Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ openTihui — needed to load your shortcuts and insert results.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 25).onEnded { v in
                if v.translation.height > 35, abs(v.translation.height) > abs(v.translation.width) {
                    withAnimation(.easeInOut(duration: 0.2)) { showActions = false }
                }
            }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
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

    // MARK: typing pad

    /// QWERTY keys with numbers/symbols layers. Swipe up to reveal the AI panel.
    private var typingPad: some View {
        GeometryReader { geo in
            let gap: CGFloat = 6
            let unit = (geo.size.width - gap * 9) / 10
            let keyH = (geo.size.height - gap * 3) / 4
            VStack(spacing: gap) {
                switch layer {
                case .letters:
                    charRow("qwertyuiop", unit: unit, gap: gap, h: keyH)
                    charRow("asdfghjkl", unit: unit, gap: gap, h: keyH)
                    HStack(spacing: gap) {
                        controlKey(icon: capsLock ? "capslock.fill" : (shifted ? "shift.fill" : "shift"),
                                   width: unit * 1.4, h: keyH, action: tapShift)
                        Spacer(minLength: 0)
                        charRow("zxcvbnm", unit: unit, gap: gap, h: keyH)
                        Spacer(minLength: 0)
                        controlKey(icon: "delete.left", width: unit * 1.4, h: keyH) { actions.deleteBackward() }
                    }
                case .numbers:
                    charRow("1234567890", unit: unit, gap: gap, h: keyH)
                    charRow("-/:;()$&@“", unit: unit, gap: gap, h: keyH)
                    HStack(spacing: gap) {
                        controlKey(text: "#+=", width: unit * 1.4, h: keyH) { layer = .symbols }
                        Spacer(minLength: 0)
                        charRow(".,?!’", unit: unit * 1.3, gap: gap, h: keyH)
                        Spacer(minLength: 0)
                        controlKey(icon: "delete.left", width: unit * 1.4, h: keyH) { actions.deleteBackward() }
                    }
                case .symbols:
                    charRow("[]{}#%^*+=", unit: unit, gap: gap, h: keyH)
                    charRow("_\\|~<>€£¥·", unit: unit, gap: gap, h: keyH)
                    HStack(spacing: gap) {
                        controlKey(text: "123", width: unit * 1.4, h: keyH) { layer = .numbers }
                        Spacer(minLength: 0)
                        charRow(".,?!’", unit: unit * 1.3, gap: gap, h: keyH)
                        Spacer(minLength: 0)
                        controlKey(icon: "delete.left", width: unit * 1.4, h: keyH) { actions.deleteBackward() }
                    }
                }
                HStack(spacing: gap) {
                    controlKey(text: layer == .letters ? "123" : "ABC", width: unit * 1.6, h: keyH) {
                        layer = (layer == .letters) ? .numbers : .letters
                    }
                    controlKey(icon: "sparkles", width: unit * 1.3, h: keyH) {
                        withAnimation(.easeInOut(duration: 0.2)) { showActions = true }
                    }
                    Button { actions.insert(" ") } label: {
                        Text(verbatim: "space").font(.system(size: 15)).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity).frame(height: keyH)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    controlKey(icon: "return", width: unit * 2.0, h: keyH) { actions.insert("\n") }
                }
            }
        }
        .frame(minHeight: 204, maxHeight: .infinity)   // fill like the AI panel does
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 25).onEnded { v in
                if v.translation.height < -35, abs(v.translation.height) > abs(v.translation.width) {
                    withAnimation(.easeInOut(duration: 0.2)) { showActions = true }
                }
            }
        )
    }

    /// A centered row of character keys.
    private func charRow(_ chars: String, unit: CGFloat, gap: CGFloat, h: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(chars), id: \.self) { c in
                let s = String(c)
                Button { tapChar(s) } label: {
                    Text(displayChar(s)).font(.system(size: 22)).foregroundStyle(.primary)
                        .frame(width: unit, height: h)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func controlKey(icon: String? = nil, text: String? = nil,
                            width: CGFloat, h: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 17)) }
                else if let text { Text(verbatim: text).font(.system(size: 15)) }
            }
            .foregroundStyle(.primary)
            .frame(width: width, height: h)
            .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func displayChar(_ c: String) -> String {
        (layer == .letters && (shifted || capsLock)) ? c.uppercased() : c
    }

    private func tapChar(_ c: String) {
        actions.insert(displayChar(c))
        if shifted && !capsLock { shifted = false }   // shift applies to one letter
    }

    /// Tap toggles shift; a quick double-tap locks caps.
    private func tapShift() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.35 {
            capsLock = true; shifted = true
        } else if capsLock {
            capsLock = false; shifted = false
        } else {
            shifted.toggle()
        }
        lastShiftTap = now
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
            Button { withAnimation(.easeInOut(duration: 0.2)) { showActions = false } } label: {
                Image(systemName: "keyboard")
                    .font(.callout).frame(width: 44).padding(.vertical, 9)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

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
        // Prefer a result handed over via the shared App Group (no clipboard
        // needed, so no iOS paste prompt); fall back to the clipboard.
        if let result = KBShared.takeResult() {
            actions.insert(result)
            status = .idle
            return
        }
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

    /// Refresh the chips on every appearance: prefer the app's setup in the
    /// shared App Group container (auto-sync); fall back to a setup payload on
    /// the clipboard (builds without the App Group entitlement).
    private func autoImportIfNeeded() {
        guard actions.hasFullAccess() else { return }
        if let shared = KBShared.config() {
            if shared != config { shared.save(); config = shared }
            return
        }
        guard config.actions.isEmpty else { return }
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
