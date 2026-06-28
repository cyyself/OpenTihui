//
//  ScreenshotSuggester.swift
//  openTihui
//
//  Detects a screenshot taken in the last 30s and offers to attach it to the
//  current message (like the iOS share-screenshot affordance).
//

import SwiftUI
import Photos

@MainActor
final class ScreenshotSuggester: ObservableObject {
    @Published var image: UIImage?

    private var lastOfferedAssetID: String?
    private var observing = false

    /// Begin watching for screenshots. Pass `vision` so we only bother when the
    /// loaded model can actually use an image.
    func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScreenshot),
                                               name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        // On open, only surface an existing recent screenshot if already authorized
        // (don't prompt for permission until the user actually screenshots).
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            findRecentScreenshot(promptIfNeeded: false)
        }
    }

    func stop() {
        observing = false
        NotificationCenter.default.removeObserver(self)
    }

    func dismiss() { image = nil }

    @objc private func didScreenshot() {
        // Give the system a moment to write the screenshot to the library.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.findRecentScreenshot(promptIfNeeded: true)
        }
    }

    private func findRecentScreenshot(promptIfNeeded: Bool) {
        ensureAuthorized(prompt: promptIfNeeded) { [weak self] granted in
            guard granted, let self else { return }
            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = 1
            let result = PHAsset.fetchAssets(with: .image, options: opts)
            guard let asset = result.firstObject,
                  let date = asset.creationDate,
                  Date().timeIntervalSince(date) <= 30,
                  asset.localIdentifier != self.lastOfferedAssetID else { return }
            self.loadImage(for: asset)
        }
    }

    private func loadImage(for asset: PHAsset) {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        let target = CGSize(width: 1024, height: 1024)
        PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: opts) { [weak self] img, _ in
            guard let img else { return }
            Task { @MainActor in
                self?.lastOfferedAssetID = asset.localIdentifier
                self?.image = img
            }
        }
    }

    private func ensureAuthorized(prompt: Bool, _ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined where prompt:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                DispatchQueue.main.async { completion(s == .authorized || s == .limited) }
            }
        default:
            completion(false)
        }
    }

    /// Fetch the most recent screenshot taken within `maxAge` seconds (requesting
    /// Photos access if needed). Used to auto-attach context for shortcuts.
    static func recentScreenshot(maxAge: TimeInterval = 30) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let granted: Bool
        switch status {
        case .authorized, .limited: granted = true
        case .notDetermined:
            granted = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                    cont.resume(returning: s == .authorized || s == .limited)
                }
            }
        default: granted = false
        }
        guard granted else { return nil }

        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        let result = PHAsset.fetchAssets(with: .image, options: opts)
        guard let asset = result.firstObject, let date = asset.creationDate,
              Date().timeIntervalSince(date) <= maxAge else { return nil }

        let req = PHImageRequestOptions()
        req.deliveryMode = .highQualityFormat   // single callback (no degraded pass)
        req.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                                  contentMode: .aspectFit, options: req) { img, _ in
                cont.resume(returning: img)
            }
        }
    }
}
