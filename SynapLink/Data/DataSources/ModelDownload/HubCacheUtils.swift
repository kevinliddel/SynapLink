//
//  HubCacheUtils.swift
//  SynapLink
//
//  Disk accounting and cleanup for the Hugging Face Hub snapshot cache
//  (Application Support/hub/models--{org}--{repo}/...).
//

import Foundation

enum HubCacheUtils {

    static var hubRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hub")
    }

    static func cacheURL(for config: ModelConfiguration) -> URL {
        hubRootURL.appendingPathComponent(config.hubSlug)
    }

    /// Allocated bytes (matches iOS Settings' "Documents & Data" accounting,
    /// which includes filesystem block padding).
    static func directoryBytes(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles])
        var total: Int64 = 0
        while let next = enumerator?.nextObject() as? URL {
            let values = try? next.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func bytesOnDisk(for config: ModelConfiguration) -> Int64 {
        directoryBytes(at: cacheURL(for: config))
    }

    static var totalBytes: Int64 {
        directoryBytes(at: hubRootURL)
    }

    static func clear(_ config: ModelConfiguration) {
        try? FileManager.default.removeItem(at: cacheURL(for: config))
        config.clearPersistedPaths()
    }
}
