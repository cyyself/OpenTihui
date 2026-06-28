//
//  OpenAIClient.swift
//  openTihui
//
//  Minimal streaming client for the OpenAI-compatible /chat/completions API.
//

import Foundation
import UIKit

struct ChatTurn {
    enum Role: String { case system, user, assistant }
    var role: Role
    var text: String
    var imagePaths: [String] = []
}

enum OpenAIClient {

    /// Stream a completion. Yields token pieces, then a final done/failed event.
    static func stream(endpoint: RemoteEndpoint,
                       turns: [ChatTurn],
                       config: GenConfig) -> AsyncStream<GenerationEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    guard let url = endpoint.chatCompletionsURL else {
                        continuation.yield(.failed("Invalid base URL")); continuation.finish(); return
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !endpoint.apiKey.isEmpty {
                        req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    req.httpBody = try body(endpoint: endpoint, turns: turns, config: config)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var detail = ""
                        for try await line in bytes.lines { detail += line }
                        continuation.yield(.failed("HTTP \(http.statusCode): \(detail.prefix(200))"))
                        continuation.finish(); return
                    }

                    var count = 0
                    let start = Date()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let piece = parseDelta(data) else { continue }
                        if !piece.isEmpty { count += 1; continuation.yield(.token(piece)) }
                    }
                    let secs = Date().timeIntervalSince(start)
                    let tps = secs > 0 ? Double(count) / secs : 0
                    continuation.yield(.done(stats: String(format: "%.1f tok/s · %@", tps, endpoint.modelID)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Request building

    private static func body(endpoint: RemoteEndpoint, turns: [ChatTurn], config: GenConfig) throws -> Data {
        var messages: [[String: Any]] = []
        for turn in turns {
            if turn.imagePaths.isEmpty {
                messages.append(["role": turn.role.rawValue, "content": turn.text])
            } else {
                var parts: [[String: Any]] = []
                if !turn.text.isEmpty { parts.append(["type": "text", "text": turn.text]) }
                for path in turn.imagePaths {
                    if let dataURL = imageDataURL(path) {
                        parts.append(["type": "image_url", "image_url": ["url": dataURL]])
                    }
                }
                messages.append(["role": turn.role.rawValue, "content": parts])
            }
        }

        var payload: [String: Any] = [
            "model": endpoint.modelID,
            "messages": messages,
            "stream": true,
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_tokens": config.maxTokens,
        ]
        if config.thinkingEffort != .off, config.thinkingEffort != .high {
            payload["reasoning_effort"] = config.thinkingEffort.label.lowercased()  // for models that support it
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func imageDataURL(_ path: String) -> String? {
        guard let img = UIImage(contentsOfFile: path),
              let data = img.jpegData(compressionQuality: 0.85) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func parseDelta(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }
}
