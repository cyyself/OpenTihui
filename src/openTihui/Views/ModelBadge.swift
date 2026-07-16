//
//  ModelBadge.swift
//  openTihui
//
//  A small gradient logo badge for a model, inferred from its name — a
//  monogram or symbol per family (Qwen, Gemma, Llama, …). Self-contained
//  (no trademarked artwork), consistent in the catalog and model lists.
//

import SwiftUI

struct ModelBadge: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        let s = style
        Group {
            // Prefer the bundled org logo (fetched from Hugging Face by
            // scripts/fetch-model-logos.sh); fall back to a gradient monogram.
            if !s.asset.isEmpty, let ui = UIImage(named: "model-logo-\(s.asset)") {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.24)
                    .fill(LinearGradient(colors: s.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        if let icon = s.icon {
                            Image(systemName: icon)
                                .font(.system(size: size * 0.42, weight: .semibold))
                                .foregroundStyle(.white)
                        } else {
                            Text(s.monogram)
                                .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
    }

    private var style: (monogram: String, icon: String?, colors: [Color], asset: String) {
        let n = name.lowercased()
        if n.contains("qwen") {
            return ("Q", nil, [Color(red: 0.42, green: 0.31, blue: 0.95), Color(red: 0.71, green: 0.33, blue: 0.97)], "qwen")
        }
        if n.contains("gemma") {
            return ("G", nil, [Color(red: 0.10, green: 0.42, blue: 0.94), Color(red: 0.26, green: 0.72, blue: 0.98)], "gemma")
        }
        if n.contains("bonsai") {
            return ("B", "tree.fill", [Color(red: 0.09, green: 0.55, blue: 0.33), Color(red: 0.33, green: 0.78, blue: 0.42)], "bonsai")
        }
        if n.contains("llama") {
            return ("L", nil, [Color(red: 0.85, green: 0.40, blue: 0.12), Color(red: 0.95, green: 0.63, blue: 0.22)], "llama")
        }
        if n.contains("mistral") || n.contains("mixtral") {
            return ("M", nil, [Color(red: 0.90, green: 0.30, blue: 0.15), Color(red: 0.98, green: 0.60, blue: 0.10)], "mistral")
        }
        if n.contains("deepseek") {
            return ("D", nil, [Color(red: 0.15, green: 0.30, blue: 0.85), Color(red: 0.35, green: 0.55, blue: 0.98)], "deepseek")
        }
        if n.contains("phi") {
            return ("φ", nil, [Color(red: 0.05, green: 0.55, blue: 0.60), Color(red: 0.20, green: 0.75, blue: 0.70)], "phi")
        }
        return ("", "cpu", [Color(.systemGray2), Color(.systemGray)], "")
    }
}
