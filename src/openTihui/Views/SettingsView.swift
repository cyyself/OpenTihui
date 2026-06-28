//
//  SettingsView.swift
//  openTihui
//
//  Global / device settings. Per-chat tuning lives in Chat Settings / Shortcuts.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var chat: ChatViewModel
    @EnvironmentObject var shortcuts: ShortcutStore

    @State private var confirmReset = false

    var body: some View {
        Form {
            // Models live directly at the top of Settings.
            ModelManagerView()

            Section("openTihui Keyboard") {
                NavigationLink {
                    KeyboardSettingsView()
                } label: {
                    Label("Configure keyboard actions", systemImage: "keyboard")
                }
            }

            Section {
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 90).font(.callout)
            } header: {
                Text("Default System Prompt")
            } footer: {
                Text("Used for new chats that aren’t started from a shortcut. Context length, sampling and reasoning are tuned per-chat (Chat Settings) or in a Shortcut.")
            }

            Section {
                NavigationLink {
                    DefaultChatSettingsView()
                } label: {
                    Label("Default Generation Settings", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("Context, reasoning, sampling and image size for new chats and the keyboard’s “Generate in app”. Shortcuts use their own settings.")
            }

            Section("Shortcuts") {
                Button("Reset Shortcuts to Default", role: .destructive) { confirmReset = true }
            }

            Section("About") {
                LabeledContent("Engine", value: "llama.cpp")
                // GPU (Metal) is used automatically when the device supports it.
                // Both values come from already-resolved state (the off-main probe
                // and the loaded model), so rendering Settings never blocks.
                LabeledContent("GPU acceleration", value: gpuStatusText)
                LabeledContent("Active backend", value: chat.modelInfo?.backend ?? String(localized: "Not loaded"))
                NavigationLink {
                    LogView()
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/cyyself/OpenTihui")!) {
                    HStack {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Project")
            } footer: {
                Text("openTihui is open source — contributions are welcome!")
            }

            Section {
                acknowledgement("llama.cpp", license: "MIT License",
                                url: "https://github.com/ggml-org/llama.cpp/blob/master/LICENSE")
                acknowledgement("ggml", license: "MIT License",
                                url: "https://github.com/ggml-org/ggml/blob/master/LICENSE")
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("openTihui is built on these open-source projects. Tap to view their licenses.")
            }
        }
        .confirmationDialog("Reset all shortcuts to the built-in defaults? Your custom shortcuts will be removed.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Shortcuts", role: .destructive) { shortcuts.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if chat.isLoadingModel {
                ProgressView("Applying…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// Device GPU capability, from the off-main probe (never blocks). `nil` while
    /// the probe is still running shortly after launch.
    private var gpuStatusText: String {
        switch settings.gpuSupported {
        case .some(true):  return "Metal"
        case .some(false): return String(localized: "Not supported on this device")
        case .none:        return String(localized: "Checking…")
        }
    }

    @ViewBuilder
    private func acknowledgement(_ name: String, license: LocalizedStringKey, url: String) -> some View {
        if let link = URL(string: url) {
            Link(destination: link) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).foregroundStyle(.primary)
                        Text(license).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
