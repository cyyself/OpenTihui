//
//  ChatExporter.swift
//  openTihui
//
//  Export a conversation as a self-contained JSON file (images embedded as
//  base64) or a paginated PDF.
//

import Foundation
import UIKit
import CoreText

enum ChatExporter {

    // MARK: JSON (images embedded as base64)

    struct ExportAttachment: Codable {
        var kind: String          // "image" | "audio"
        var filename: String
        var dataBase64: String?
    }
    struct ExportMessage: Codable {
        var role: String          // "user" | "assistant"
        var text: String
        var attachments: [ExportAttachment]
        var stats: String?
    }
    struct ExportChat: Codable {
        var title: String
        var exportedAt: Date
        var model: String?
        var systemPrompt: String?
        var messages: [ExportMessage]
    }

    static func jsonData(title: String, model: String?, systemPrompt: String?,
                         messages: [ChatMessage], exportedAt: Date) throws -> Data {
        let msgs = messages.map { m in
            ExportMessage(role: m.role == .user ? "user" : "assistant",
                          text: m.text,
                          attachments: m.attachments.map { att in
                              ExportAttachment(kind: att.kind == .audio ? "audio" : "image",
                                               filename: att.url.lastPathComponent,
                                               dataBase64: (try? Data(contentsOf: att.url))?.base64EncodedString())
                          },
                          stats: m.stats)
        }
        let chat = ExportChat(title: title, exportedAt: exportedAt, model: model,
                              systemPrompt: systemPrompt, messages: msgs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(chat)
    }

    // MARK: PDF (paginated via Core Text — runs off the main thread)

    private static let pageSize = CGSize(width: 612, height: 792)         // US Letter @72dpi
    private static let margin: CGFloat = 40

    /// Render the chat to a paginated PDF. Uses Core Text + `UIGraphicsPDFRenderer`,
    /// both of which are thread-safe, so this can run off the main thread and let
    /// the UI show a live "preparing…" indicator.
    static func pdfData(title: String, subtitle: String, messages: [ChatMessage]) -> Data {
        let contentW = pageSize.width - margin * 2
        let bottomY = pageSize.height - margin
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        // Fixed (non-dynamic) colors so nothing has to resolve a trait collection off-main.
        let ink = UIColor(white: 0.11, alpha: 1)
        let grey = UIColor(white: 0.55, alpha: 1)
        let blue = UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
        let body = UIFont.systemFont(ofSize: 12)

        return renderer.pdfData { ctx in
            let cg = ctx.cgContext
            var y = margin
            ctx.beginPage()

            func newPage() { ctx.beginPage(); y = margin }

            /// Draw an attributed string with Core Text, paginating as needed.
            func draw(_ attr: NSAttributedString, gapAfter: CGFloat) {
                let fs = CTFramesetterCreateWithAttributedString(attr)
                var start = 0
                let total = attr.length
                while start < total {
                    if bottomY - y < body.lineHeight { newPage() }
                    let avail = CGSize(width: contentW, height: bottomY - y)
                    var fitRange = CFRange()
                    let used = CTFramesetterSuggestFrameSizeWithConstraints(
                        fs, CFRangeMake(start, 0), nil, avail, &fitRange)
                    if fitRange.length == 0 { break }
                    let h = ceil(used.height)
                    let path = CGPath(rect: CGRect(x: 0, y: 0, width: contentW, height: h), transform: nil)
                    let frame = CTFramesetterCreateFrame(fs, CFRangeMake(start, fitRange.length), path, nil)
                    cg.saveGState()
                    cg.translateBy(x: margin, y: y + h)   // flip into Core Text's y-up space
                    cg.scaleBy(x: 1, y: -1)
                    CTFrameDraw(frame, cg)
                    cg.restoreGState()
                    y += h
                    start += fitRange.length
                }
                y += gapAfter
            }

            func drawImage(_ img: UIImage) {
                let scale = min(contentW / img.size.width, 340 / img.size.height, 1)
                let w = img.size.width * scale, h = img.size.height * scale
                if y + h > bottomY { newPage() }
                img.draw(in: CGRect(x: margin, y: y, width: w, height: h))
                y += h + 8
            }

            func rule() {
                cg.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
                cg.setLineWidth(0.5)
                cg.move(to: CGPoint(x: margin, y: y)); cg.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
                cg.strokePath(); y += 10
            }

            draw(NSAttributedString(string: title, attributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: ink]), gapAfter: 2)
            draw(NSAttributedString(string: subtitle, attributes: [.font: body, .foregroundColor: grey]), gapAfter: 8)
            rule()

            for m in messages {
                let isUser = m.role == .user
                draw(NSAttributedString(string: isUser ? "You" : "Assistant",
                                        attributes: [.font: UIFont.boldSystemFont(ofSize: 13), .foregroundColor: isUser ? blue : ink]), gapAfter: 3)
                for att in m.attachments where att.kind == .image {
                    if let data = try? Data(contentsOf: att.url), let img = UIImage(data: data) { drawImage(img) }
                }
                let text = isUser ? m.text : splitReasoning(m.text).answer   // strip <think> for assistant
                if !text.isEmpty {
                    draw(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: ink]), gapAfter: 14)
                }
            }
        }
    }

    // MARK: helpers

    /// Write `data` to a temp file with a filesystem-safe name and return its URL.
    static func tempFile(named base: String, ext: String, data: Data) -> URL? {
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let name = (safe.isEmpty ? "chat" : String(safe.prefix(60))) + "." + ext
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}
