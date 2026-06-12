//
//  ProtectedStorage.swift
//  SynapLink
//
//  Encrypted-at-rest file storage (PLAN.md §3): app-private directory under
//  Application Support with NSFileProtectionComplete, excluded from iCloud
//  backup. SQLCipher page-level encryption is a Phase 5 (security pass)
//  opt-in on top of this — same staged approach NeuraLink used.
//

import Foundation

enum ProtectedStorageError: Error {
    case directoryUnavailable
}

enum ProtectedStorage {

    /// App-private directory for sensitive data (chat DB, attachments).
    /// Created on first use with complete file protection and excluded from
    /// iCloud backup.
    static func privateApplicationSupportURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProtectedStorageError.directoryUnavailable
        }
        var dir = appSupport.appendingPathComponent("private", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    /// Set NSFileProtectionComplete on an existing file. Safe to call on
    /// missing paths (no-op).
    static func protect(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }
}
