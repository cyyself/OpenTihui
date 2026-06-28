//
//  Speaker.swift
//  openTihui
//
//  Text-to-speech for reading chat messages aloud (the bubble's "Speak" action).
//

import AVFoundation

final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: t)
        // Match the voice to the text's language where possible.
        if let lang = AVSpeechSynthesisVoice.currentLanguageCode() as String?,
           AVSpeechSynthesisVoice(language: lang) != nil {
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
        }
        synth.speak(utterance)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}
