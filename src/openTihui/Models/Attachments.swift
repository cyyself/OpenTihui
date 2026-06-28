//
//  Attachments.swift
//  openTihui
//
//  Helpers for turning picked photos and recorded audio into on-disk files that
//  the inference engine (libmtmd) can read.
//

import Foundation
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
