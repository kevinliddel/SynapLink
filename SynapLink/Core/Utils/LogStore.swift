//
//  LogStore.swift
//  SynapLink
//
//  The sink behind `slog`: a thread-safe in-memory ring buffer (for the
//  in-app log viewer) plus an append-only file in Application Support (for
//  export / sharing off-device). Lets us debug on-device issues — the SD /
//  whisper / engine crashes we keep hitting — without an Xcode console.
//

import Foundation

enum LogLevel: Int, Comparable, Sendable {
    case debug, info, notice, warning, error

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }

    var emoji: String {
        switch self {
        case .debug: return "⚪"
        case .info: return "🔵"
        case .notice: return "✦"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct LogEntry: Identifiable, Sendable {
    let id: UInt64
    let date: Date
    let level: LogLevel
    let category: String
    let message: String
}

/// Thread-safe; `slog` writes from any thread, the viewer reads snapshots.
final class LogStore: @unchecked Sendable {

    static let shared = LogStore()

    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var nextID: UInt64 = 0
    private let maxEntries = 1000

    private let fileQueue = DispatchQueue(label: "com.dedicatus.synaplink.logsink", qos: .utility)
    private let maxFileBytes: UInt64 = 2 * 1024 * 1024

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func record(level: LogLevel, category: String, message: String) {
        lock.lock()
        let entry = LogEntry(id: nextID, date: Date(), level: level, category: category, message: message)
        nextID += 1
        ring.append(entry)
        if ring.count > maxEntries { ring.removeFirst(ring.count - maxEntries) }
        lock.unlock()

        let line = "\(Self.stamp.string(from: entry.date)) \(level.label) [\(category)] \(message)\n"
        fileQueue.async { [weak self] in self?.append(line) }
    }

    /// Newest-first snapshot for the viewer, optionally filtered by minimum level.
    func snapshot(minLevel: LogLevel = .debug) -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return ring.reversed().filter { $0.level >= minLevel }
    }

    func clear() {
        lock.lock(); ring.removeAll(); lock.unlock()
        fileQueue.async { [weak self] in
            guard let url = self?.fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Full log text for sharing/export.
    func exportText() -> String {
        if let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
        return snapshot().reversed()
            .map { "\(Self.stamp.string(from: $0.date)) \($0.level.label) [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }

    var fileURL: URL? {
        guard let dir = try? ProtectedStorage.privateApplicationSupportURL() else { return nil }
        return dir.appendingPathComponent("synaplink.log")
    }

    // MARK: - File sink (serialized on fileQueue)

    private func append(_ line: String) {
        guard let url = fileURL, let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(data)
        rollIfNeeded(url: url, handle: handle)
    }

    /// Keep the file bounded: when it passes the cap, keep the most recent half.
    private func rollIfNeeded(url: URL, handle: FileHandle) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        guard size > maxFileBytes else { return }
        guard let all = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
