//
//  Attachments.swift
//  openTihui
//
//  Helpers for turning picked photos and recorded audio into on-disk files that
//  the inference engine (libmtmd) can read.
//

import Foundation
import AVFoundation
import UIKit

enum AttachmentStore {
    /// On-device storage for chat attachments (referenced by absolute path).
    static var directory: URL { LocalStore.attachmentsDirectory }

    /// Persist image data as a JPEG and return a file URL. `maxDimension` (longest
    /// side, in px) downscales large images before saving — fewer vision tokens
    /// and smaller files; 0 keeps the original resolution.
    static func saveImage(_ data: Data, maxDimension: Int = 0, quality: CGFloat = 0.85) -> URL? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = image.downscaled(toLongestSide: maxDimension)
        guard let jpeg = scaled.jpegData(compressionQuality: quality) else { return nil }
        let url = directory.appendingPathComponent("img-\(UUID().uuidString).jpg")
        do { try jpeg.write(to: url); return url } catch { return nil }
    }
}

extension UIImage {
    /// A copy whose longest side is at most `maxSide` px (aspect preserved).
    /// Returns self when `maxSide <= 0` or the image is already smaller.
    func downscaled(toLongestSide maxSide: Int) -> UIImage {
        let limit = CGFloat(maxSide)
        guard limit > 0 else { return self }
        let longest = max(size.width, size.height)
        guard longest > limit else { return self }
        let scale = limit / longest
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // newSize is already in pixels
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Minimal WAV recorder (16 kHz mono PCM — the rate multimodal audio models
/// expect). Recording is capped at `maxDuration` so a clip can't blow up the
/// model's context (audio tokens scale with duration) or the on-disk size
/// (16 kHz mono ≈ 1.9 MB/min); it auto-stops at the limit.
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    let maxDuration: TimeInterval = 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var lastRecordingURL: URL?
    private var consumed = true

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch { return }

        let url = AttachmentStore.directory.appendingPathComponent("audio-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            lastRecordingURL = url
            consumed = false
            elapsed = 0
            startedAt = Date()
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                if self.elapsed >= self.maxDuration { self.stop() }   // auto-stop at the cap
            }
        } catch { isRecording = false }
    }

    @discardableResult
    func stop() -> URL? {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        recorder = nil
        startedAt = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        return lastRecordingURL
    }

    /// The finished recording, returned once (so a manual *and* an auto-stop
    /// don't both attach it). Lets the view observe `isRecording → false`.
    func takeRecording() -> URL? {
        guard !consumed, let url = lastRecordingURL else { return nil }
        consumed = true
        return url
    }

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
