//
//  KeyboardSettingsView.swift
//  openTihui
//
//  Configure the openTihui keyboard: which up-to-six quick actions appear as
//  chips, and which API endpoint it uses for inline generation. The selection is
//  handed to the keyboard via a clipboard "setup" payload (no App Group, so it
//  signs fine with a free Apple account).
//

import SwiftUI

struct KeyboardSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var shortcuts: ShortcutStore
    @Environment(\.openURL) private var openURL

    @State private var copied = false
    @State private var tryText = ""
    @FocusState private var tryFocused: Bool

    /// The shortcuts shown as keyboard chips: the explicit selection, or all
    /// keyboard-enabled shortcuts when nothing has been chosen yet.
    /// Only shortcuts that opted in to keyboard chips.
    private var keyboardShortcuts: [Shortcut] { shortcuts.shortcuts.filter { $0.allowInKeyboard } }

    private var selected: [Shortcut] {
        if settings.keyboardShortcutIDs.isEmpty { return keyboardShortcuts }
        return settings.keyboardShortcutIDs.compactMap { id in keyboardShortcuts.first { $0.id.uuidString == id } }
    }
    private var available: [Shortcut] {
        let chosen = Set(selected.map { $0.id })
        return keyboardShortcuts.filter { !chosen.contains($0.id) }
    }

    private func setSelected(_ list: [Shortcut]) {
        settings.keyboardShortcutIDs = list.map { $0.id.uuidString }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Settings ▸ General ▸ Keyboard ▸ Keyboards.")
                    step(2, "Tap **Add New Keyboard…** and choose **openTihui**.")
                    step(3, "Tap **openTihui** in the list, then turn on **Allow Full Access**.")
                }
                .padding(.vertical, 2)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
            } header: {
                Text("Enable the keyboard")
            } footer: {
                Text("Full Access is required for AI generation (network) and inserting results from the clipboard. While typing in any app, long-press 🌐 and pick openTihui to switch to it.")
            }

            Section {
                ForEach(selected) { s in
                    Label(s.name, systemImage: s.icon)
                }
                .onMove { from, to in
                    var list = selected
                    list.move(fromOffsets: from, toOffset: to)
                    setSelected(list)
                }
                .onDelete { offsets in
                    var list = selected
                    list.remove(atOffsets: offsets)
                    setSelected(list)
                }
            } header: {
                HStack {
                    Text("Keyboard chips (\(selected.count))")
                    Spacer()
                    EditButton().font(.caption)
                }
            } footer: {
                Text("Your Shortcuts shown as chips in the keyboard, in this order. Drag to reorder, swipe to remove. The keyboard scrolls horizontally, so add as many as you like. Add or edit shortcuts in the Shortcuts tab.")
            }

            if !available.isEmpty {
                Section("Add a shortcut") {
                    ForEach(available) { s in
                        Button {
                            setSelected(selected + [s])
                        } label: {
                            Label(s.name, systemImage: s.icon)
                        }
                    }
                }
            }

            Section {
                Button {
                    copySetup()
                } label: {
                    Label(copied ? "Copied — switch to the keyboard & tap Import" : "Copy setup for keyboard",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
            } footer: {
                Text("Then switch to the openTihui keyboard and tap **Import shortcuts from app** (it also loads automatically the first time). Enable it first in Settings ▸ General ▸ Keyboard ▸ Keyboards, and turn on Allow Full Access.")
            }

            Section {
                TextField("Tap here, then switch to openTihui…", text: $tryText, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($tryFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { tryFocused = false }
                        }
                    }
                if !tryText.isEmpty {
                    Button("Clear", role: .destructive) { tryText = "" }
                }
            } header: {
                Text("Try it out")
            } footer: {
                Text("Tap in this box, then long-press 🌐 (or tap it) to switch to the openTihui keyboard and test your actions right here.")
            }
        }
        .navigationTitle("openTihui Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.accentColor, in: Circle())
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
    }

    private func copySetup() {
        let actions = selected.map { s in
            KBActionPayload(title: s.name, icon: s.icon, instruction: s.systemPrompt,
                            useClipboard: s.config.autoClipboard, useScreenshot: s.config.autoScreenshot)
        }
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        UIPasteboard.general.string = KBSetupPayload(actions: actions, lang: lang).encoded()
        withAnimation { copied = true }
    }
}
