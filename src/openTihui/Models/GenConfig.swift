//
//  GenConfig.swift
//  openTihui
//
//  Per-chat generation configuration: context window, sampling, and reasoning
//  effort. Carried by shortcuts and stored in each conversation.
//

import Foundation

struct GenConfig: Codable, Hashable {
    var contextLength: Int = 4096
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var topK: Int = 40
    var minP: Double = 0.05
    var repeatPenalty: Double = 1.1
    /// Max generated tokens. 0 = auto (up to the full context window).
    var maxTokens: Int = 0
    var thinkingEffortRaw: Int = ThinkingEffort.low.rawValue
    /// Load the multimodal projector (mmproj) for this chat. Off = text-only,
    /// saving memory even when the model ships a projector.
    var loadProjector: Bool = true
    /// Stateless mode: each query is answered with a fresh context (only the
    /// system prompt), so prior turns aren't kept in the KV cache. Earlier
    /// messages still show in the transcript. Good for one-shot tasks (translate).
    var discardContext: Bool = false
    /// Auto-fill the composer from the clipboard when the chat opens.
    var autoClipboard: Bool = false
    /// Auto-attach a screenshot taken in the last 30s when a message is sent /
    /// when "Generate in app" opens (requires Photos access). On by default;
    /// text-only shortcuts turn it off.
    var autoScreenshot: Bool = true
    /// Downscale attached images so their longest side is at most this many
    /// pixels before sending to the model — fewer vision tokens, faster encode,
    /// smaller storage. 0 = keep the original resolution.
    var imageMaxDimension: Int = 1024

    static let `default` = GenConfig()

    static let imageSizeOptions = [0, 512, 768, 1024, 1536, 2048]

    static let contextOptions = [2048, 4096, 8192, 16384, 32768]

    /// Default config for a new chat — multimodal models get a larger window
    /// since images consume many tokens.
    static func defaultFor(multimodal: Bool) -> GenConfig {
        var c = GenConfig.default
        if multimodal { c.contextLength = 8192 }
        return c
    }

    var thinkingEffort: ThinkingEffort {
        get { ThinkingEffort(rawValue: thinkingEffortRaw) ?? .low }
        set { thinkingEffortRaw = newValue.rawValue }
    }

    /// Effective generation cap: an explicit value, else the whole context window.
    var effectiveMaxTokens: Int { maxTokens > 0 ? maxTokens : contextLength }

    var generationParams: LMGenerationParams {
        let p = LMGenerationParams.defaults()
        p.maxTokens     = Int32(effectiveMaxTokens)
        p.temperature   = Float(temperature)
        p.topP          = Float(topP)
        p.topK          = Int32(topK)
        p.minP          = Float(minP)
        p.repeatPenalty = Float(repeatPenalty)
        p.thinkBudget   = Int32(thinkingEffort.budget)
        return p
    }
}

extension GenConfig {
    // Tolerant decoding so older saved data (missing newer keys) still loads.
    // Defined in an extension to preserve the default `GenConfig()` initializer.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextLength     = try c.decodeIfPresent(Int.self,    forKey: .contextLength) ?? contextLength
        temperature       = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        topP              = try c.decodeIfPresent(Double.self, forKey: .topP) ?? topP
        topK              = try c.decodeIfPresent(Int.self,    forKey: .topK) ?? topK
        minP              = try c.decodeIfPresent(Double.self, forKey: .minP) ?? minP
        repeatPenalty     = try c.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? repeatPenalty
        maxTokens         = try c.decodeIfPresent(Int.self,    forKey: .maxTokens) ?? maxTokens
        thinkingEffortRaw = try c.decodeIfPresent(Int.self,    forKey: .thinkingEffortRaw) ?? thinkingEffortRaw
        loadProjector     = try c.decodeIfPresent(Bool.self,   forKey: .loadProjector) ?? loadProjector
        discardContext    = try c.decodeIfPresent(Bool.self,   forKey: .discardContext) ?? discardContext
        autoClipboard     = try c.decodeIfPresent(Bool.self,   forKey: .autoClipboard) ?? autoClipboard
        autoScreenshot    = try c.decodeIfPresent(Bool.self,   forKey: .autoScreenshot) ?? autoScreenshot
        imageMaxDimension = try c.decodeIfPresent(Int.self,    forKey: .imageMaxDimension) ?? imageMaxDimension
    }
}
