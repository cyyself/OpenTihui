//
//  LocalStore.swift
//  openTihui
//
//  All app configuration is stored as plain JSON files under
//  Documents/Config, so it's visible (and portable) in the Files app. Chat
//  attachments stay under Application Support so the absolute paths saved in
//  conversations remain stable.
//

import Foundation

enum LocalStore {
    /// Config directory inside Documents (exposed via the Files app).
    static var configDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A config file URL. On first use, migrates a legacy copy from the old
    /// Application Support location so existing data isn't lost.
    static func fileURL(_ name: String) -> URL {
        let url = configDirectory.appendingPathComponent(name)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
            if fm.fileExists(atPath: legacy.path) { try? fm.copyItem(at: legacy, to: url) }
        }
        return url
    }

    /// A private data file under Application Support (NOT exposed in the Files
    /// app) — for chat history and other non-configuration data. Migrates a copy
    /// out of the visible Config folder if one ended up there.
    static func privateFileURL(_ name: String) -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(name)
        let configCopy = configDirectory.appendingPathComponent(name)
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: configCopy.path) {
            try? fm.moveItem(at: configCopy, to: url)          // move it back to private storage
        } else if fm.fileExists(atPath: configCopy.path) {
            try? fm.removeItem(at: configCopy)                 // drop the exposed duplicate
        }
        return url
    }

    /// Attachments directory (kept under Application Support — chats reference
    /// these by absolute path).
    static var attachmentsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
