//
//  SynapLog.swift
//  SynapLink
//
//  Project-wide structured logging (NeuraLink's nlLog pattern). Routes through
//  os.Logger — Xcode colors each level and Console.app filters by subsystem /
//  category — AND mirrors into LogStore so logs are viewable/exportable in the
//  app itself (Settings → Diagnostics → Logs), which is how we debug on-device
//  issues without an attached Xcode console.
//
//  Usage:
//    slog("loaded model")                 // .info
//    slog("reused \(n) tokens", .debug)
//    slog("generate failed: \(err)", .error)
//
//  The category is derived from the calling file, so Console.app shows a clean
//  per-file category. The `isEnabled` gate skips message construction when the
//  level is disabled at the OS.
//

import Foundation
import os

private enum LogHub {
    static let subsystem = "com.dedicatus.SynapLink"

    private struct Pair { let logger: Logger; let osLog: OSLog }
    private static var cache: [String: Pair] = [:]
    private static let lock = NSLock()

    static func get(_ category: String) -> (Logger, OSLog) {
        lock.lock(); defer { lock.unlock() }
        if let pair = cache[category] { return (pair.logger, pair.osLog) }
        let pair = Pair(logger: Logger(subsystem: subsystem, category: category),
                        osLog: OSLog(subsystem: subsystem, category: category))
        cache[category] = pair
        return (pair.logger, pair.osLog)
    }
}

private func deriveCategory(from fileID: StaticString) -> String {
    // "#fileID" is "Module/Path/File.swift" → "File".
    let raw = String(describing: fileID)
    let afterSlash = raw.split(separator: "/").last.map(String.init) ?? raw
    return afterSlash.replacingOccurrences(of: ".swift", with: "")
}

private func osLogType(_ level: LogLevel) -> OSLogType {
    switch level {
    case .debug: return .debug
    case .info: return .info
    case .notice: return .default
    case .warning, .error: return .error
    }
}

@inline(__always)
func slog(_ message: @autoclosure () -> String,
          _ level: LogLevel = .info,
          category: StaticString = #fileID,
          function: StaticString = #function,
          line: UInt = #line) {
    let cat = deriveCategory(from: category)
    let (logger, osLog) = LogHub.get(cat)
    guard osLog.isEnabled(type: osLogType(level)) else { return }

    let body = message()
    let tail = "[\(String(describing: function))#\(line)]"
    let full = "\(level.emoji) \(body) \(tail)"

    switch level {
    case .debug: logger.debug("\(full, privacy: .public)")
    case .info: logger.info("\(full, privacy: .public)")
    case .notice: logger.notice("\(full, privacy: .public)")
    case .warning, .error: logger.error("\(full, privacy: .public)")
    }

    LogStore.shared.record(level: level, category: cat, message: body)
}
