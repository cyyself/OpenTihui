//
//  VariableDefsEditor.swift
//  openTihui
//
//  Edit the variables a system prompt can use (referenced as $name). Each
//  variable has a name and an optional list of choices (no choices = free text).
//  Used from both Shortcut settings and Chat settings.
//

import SwiftUI

struct VariableDefsEditor: View {
    @Binding var defs: [PromptVariableDef]

    var body: some View {
        List {
            if defs.isEmpty {
                Section {
                    Text("No variables yet. Add one, then reference it as **$name** in the system prompt.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            ForEach($defs) { $def in
                Section {
                    HStack(spacing: 1) {
                        Text("$").foregroundStyle(.blue)
                        TextField("name", text: Binding(
                            get: { def.name },
                            set: { $def.name.wrappedValue = PromptTemplate.sanitizeName($0) }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .font(.headline)

                    ForEach(def.options.indices, id: \.self) { i in
                        TextField("Option \(i + 1)", text: $def.options[i])
                    }
                    .onDelete { $def.options.wrappedValue.remove(atOffsets: $0) }

                    Button { $def.options.wrappedValue.append("") } label: {
                        Label("Add option", systemImage: "plus")
                    }
                } footer: {
                    if def.options.isEmpty {
                        Text("No options → a free-text field.")
                    }
                }
            }
            .onDelete { defs.remove(atOffsets: $0) }

            Section {
                Button {
                    defs.append(PromptVariableDef(name: PromptTemplate.sanitizeName("var\(defs.count + 1)"), options: [""]))
                } label: {
                    Label("Add variable", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}
