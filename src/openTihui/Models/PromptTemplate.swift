//
//  PromptTemplate.swift
//  openTihui
//
//  System prompts reference variables as `$name` (or `${name}`). The variables
//  themselves — name + list of options — are defined separately (in shortcut /
//  chat settings) as `PromptVariableDef`, not inline in the prompt text.
//
//  e.g. prompt: "Translate the message into $language."
//       defs:   [language: English | Chinese | Spanish]
//

import Foundation

/// A defined variable: a name plus selectable options (empty options = free text).
struct PromptVariableDef: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var options: [String] = []
}

/// A variable as resolved for the UI (referenced in a prompt, options from defs).
struct PromptVariable: Identifiable, Equatable, Hashable {
    let name: String
    let options: [String]
    var id: String { name }
    var isSelection: Bool { !options.isEmpty }
    var defaultValue: String { options.first ?? "" }
    /// "myVar" -> "My Var" for display.
    var label: String {
        var out = ""
        for (i, ch) in name.enumerated() {
            if ch == "_" { out += " "; continue }
            if i > 0 && ch.isUppercase { out += " " }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

enum PromptTemplate {
    /// Matches `${name}` (group 1) or `$name` (group 2).
    static let token = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)

    private static func name(of match: NSTextCheckingResult, in ns: NSString) -> String {
        let r = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        return ns.substring(with: r)
    }

    /// Variable names referenced by the template, first-seen order.
    static func referencedNames(in template: String) -> [String] {
        let ns = template as NSString
        var seen = Set<String>(); var order: [String] = []
        for m in token.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            let n = name(of: m, in: ns)
            if seen.insert(n).inserted { order.append(n) }
        }
        return order
    }

    /// The variables to show for a prompt: referenced names with options looked
    /// up from `defs`.
    static func variables(in template: String, defs: [PromptVariableDef]) -> [PromptVariable] {
        let defMap = Dictionary(defs.map { ($0.name, $0.options) }, uniquingKeysWith: { a, _ in a })
        return referencedNames(in: template).map { PromptVariable(name: $0, options: defMap[$0] ?? []) }
    }

    static func hasVariables(_ template: String) -> Bool { !referencedNames(in: template).isEmpty }

    /// Substitute `$name` references with their chosen value (or the variable's
    /// default option).
    static func resolve(_ template: String, defs: [PromptVariableDef], values: [String: String]) -> String {
        let vars = variables(in: template, defs: defs)
        func value(for name: String) -> String {
            if let v = values[name], !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
            return vars.first { $0.name == name }?.defaultValue ?? ""
        }
        let ns = template as NSString
        let out = NSMutableString(string: template)
        for m in token.matches(in: template, range: NSRange(location: 0, length: ns.length)).reversed() {
            out.replaceCharacters(in: m.range, with: value(for: name(of: m, in: ns)))
        }
        return out as String
    }

    /// Ranges of `$name` tokens (whole token incl. the `$`) for highlighting.
    static func tokenRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return token.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range }
    }

    /// Sanitize a typed variable name to a valid identifier.
    static func sanitizeName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: " ", with: "_")
        s = String(s.unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains($0) })
        if let first = s.first, first.isNumber { s = "_" + s }
        return s
    }
}
