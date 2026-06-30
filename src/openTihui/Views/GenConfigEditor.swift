//
//  GenConfigEditor.swift
//  openTihui
//
//  Reusable Form sections for editing a GenConfig (context, reasoning, sampling).
//

import SwiftUI

struct GenConfigEditor: View {
    @Binding var config: GenConfig

    var body: some View {
        Section {
            Picker("Context length", selection: $config.contextLength) {
                ForEach(GenConfig.contextOptions, id: \.self) { Text("\($0) tokens").tag($0) }
            }
        } header: {
            Text("Context")
        } footer: {
            Text("When the window fills, the oldest middle of the chat is auto-compacted (the system prompt is kept).")
        }

        Section("Reasoning") {
            Picker("Thinking effort", selection: $config.thinkingEffort) {
                ForEach(ThinkingEffort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }

        Section {
            Toggle("Multimodal (load projector)", isOn: $config.loadProjector)
            Toggle("Stateless (discard context)", isOn: $config.discardContext)
        } header: {
            Text("Behavior")
        } footer: {
            Text("Turn off multimodal to save memory on text-only chats (skips loading the vision projector). Stateless answers each message with a fresh context — earlier turns stay in the transcript but aren't sent to the model, keeping the KV cache small (great for translation and other one-shot tasks).")
        }

        Section {
            Picker("Max image size", selection: $config.imageMaxDimension) {
                ForEach(GenConfig.imageSizeOptions, id: \.self) { opt in
                    Text(opt == 0 ? "Original" : "\(opt) px").tag(opt)
                }
            }
        } header: {
            Text("Images")
        } footer: {
            Text("Downscale attached images so the longest side is at most this size before sending — fewer vision tokens, faster encoding, smaller files. “Original” keeps full resolution.")
        }

        Section {
            Toggle(isOn: $config.autoClipboard) { Label("Auto-fill from clipboard", systemImage: "doc.on.clipboard") }
            Toggle(isOn: $config.autoScreenshot) { Label("Suggest recent screenshot", systemImage: "camera.viewfinder") }
        } header: {
            Text("Auto context")
        } footer: {
            Text("When the chat opens, prefill the composer with the clipboard text. After you take a screenshot, offer to attach it (tap Add) — it's never attached without your tap. Asks for Photos access. Works in normal chats and shortcuts.")
        }

        Section {
            sliderRow("Temperature", $config.temperature, 0...2, 0.05, "%.2f")
            sliderRow("Top-P", $config.topP, 0...1, 0.01, "%.2f")
            stepperRow("Top-K", $config.topK, 0...200, 5)
            sliderRow("Min-P", $config.minP, 0...1, 0.01, "%.2f")
            sliderRow("Repeat penalty", $config.repeatPenalty, 1...2, 0.01, "%.2f")
            Stepper(value: $config.maxTokens, in: 0...32768, step: 256) {
                HStack {
                    Text("Max tokens")
                    Spacer()
                    Text(config.maxTokens == 0 ? "Auto" : "\(config.maxTokens)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("Sampling")
        } footer: {
            Text("“Auto” lets a reply run up to the full context window.")
        }
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func stepperRow(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
