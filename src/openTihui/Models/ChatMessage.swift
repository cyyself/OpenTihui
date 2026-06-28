//
//  ChatMessage.swift
//  openTihui
//

import Foundation

struct Attachment: Identifiable, Hashable {
    enum Kind { case image, audio }
    let id = UUID()
    var kind: Kind
    var url: URL            // local file URL passed to the inference engine
}

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var attachments: [Attachment] = []
    var stats: String? = nil
    var isStreaming: Bool = false
    var failed: Bool = false

    var imagePaths: [String] { attachments.filter { $0.kind == .image }.map { $0.url.path } }
    var audioPaths: [String] { attachments.filter { $0.kind == .audio }.map { $0.url.path } }
}
