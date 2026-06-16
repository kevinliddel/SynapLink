//
//  ModelDownloadManager.swift
//  SynapLink
//
//  First-run model download via the Hugging Face Hub library — the proven
//  NeuraLink approach: HubApi.snapshot(matching:) fetches ONLY the files we
//  need (bartowski/unsloth-style repos hold 15+ quant variants; an unfiltered
//  snapshot would pull tens of GB). Files land in Application Support/hub/
//  and integrity is verified by the Hub library against HF's LFS metadata.
//
//  Pause/resume is task-level (cancel + restart); the Hub library reuses
//  completed file parts, so a resume does not start from zero.
//

import Foundation
import Hub
import Observation
#if canImport(UIKit)
import UIKit
#endif

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case paused(progress: Double)
    case ready
    case failed(String)
}

@MainActor
@Observable
final class ModelDownloadManager {

    static let shared = ModelDownloadManager()

    private static let configKey = "SynapLinkSelectedModelConfig"

    private(set) var states: [ModelConfiguration: ModelDownloadState] = [:]
    var selectedConfig: ModelConfiguration {
        didSet { UserDefaults.standard.set(selectedConfig.rawValue, forKey: Self.configKey) }
    }

    /// True when the selected model (and its mmproj, if any) is on disk.
    var isAvailable: Bool { states[selectedConfig] == .ready }

    /// One download at a time — used to disable other cards' buttons.
    var isDownloadActive: Bool {
        states.values.contains { if case .downloading = $0 { return true } else { return false } }
    }

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeConfig: ModelConfiguration?
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.configKey),
           let config = ModelConfiguration(rawValue: saved),
           config.isSupportedOnThisDevice {
            selectedConfig = config
        } else {
            // No selection yet — or a selection this device can't run
            // (e.g. E2B chosen before RAM gating existed).
            selectedConfig = .defaultConfigForCurrentDevice()
        }
        refreshStates()
    }

    func refreshStates() {
        for config in ModelConfiguration.allCases {
            // Don't clobber an in-flight download's live state.
            if config == activeConfig { continue }
            states[config] = config.isInstalled ? .ready : .notDownloaded
        }
    }

    // MARK: - Download

    func startDownload(_ config: ModelConfiguration) {
        guard activeTask == nil else { return }
        guard states[config] != .ready else { return }
        // Don't let users burn 4 GB of data on a model the device can't run.
        guard config.isSupportedOnThisDevice else { return }

        activeConfig = config
        states[config] = .downloading(progress: 0)
        beginBackgroundTask()
        slog("downloading \(config.rawValue) from \(config.repoID)", .info)

        activeTask = Task { [weak self] in
            do {
                try await Self.download(config) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeConfig == config else { return }
                        self.states[config] = .downloading(progress: progress)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.states[config] = config.isInstalled ? .ready : .failed("File missing after download")
                slog("download finished: \(config.rawValue) installed=\(config.isInstalled)", .info)
            } catch is CancellationError {
                // pause/cancel path — state already set by the caller
            } catch {
                if !Task.isCancelled {
                    slog("download failed for \(config.rawValue): \(error.localizedDescription)", .error)
                    self?.states[config] = .failed(error.localizedDescription)
                }
            }
            self?.activeTask = nil
            self?.activeConfig = nil
            self?.endBackgroundTask()
        }
    }

    /// Hub snapshot of exactly the files this configuration needs. Progress
    /// is capped at 0.95; the final 5% closes after path resolution succeeds.
    private static func download(_ config: ModelConfiguration,
                                 progressHandler: @escaping (Double) -> Void) async throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The Hub library lays out appSupport/hub/models--{org}--{repo}/snapshots/…
        let api = HubApi(downloadBase: appSupport)
        let repo = Hub.Repo(id: config.repoID)

        var matching = [config.filename]
        if let mmproj = config.mmprojFilename {
            matching.append(mmproj)
        }

        let snapshotDir = try await api.snapshot(from: repo, matching: matching) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }

        try verifyAndPersist(config, snapshotDir: snapshotDir)
        progressHandler(1.0)
    }

    private static func verifyAndPersist(_ config: ModelConfiguration, snapshotDir: URL) throws {
        func locate(_ filename: String) throws -> URL {
            let direct = snapshotDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            // Hub may place files one level deeper — scan one level.
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries {
                let candidate = entry.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            throw ModelDownloadError.fileMissing(filename)
        }

        config.persistPath(try locate(config.filename), key: config.pathKey)
        if let mmproj = config.mmprojFilename {
            config.persistPath(try locate(mmproj), key: config.mmprojPathKey)
        }
    }

    // MARK: - Pause / resume / delete

    func pauseDownload() {
        guard let config = activeConfig,
              case .downloading(let progress) = states[config] else { return }
        activeTask?.cancel()
        activeTask = nil
        activeConfig = nil
        states[config] = .paused(progress: progress)
        endBackgroundTask()
    }

    /// The Hub library resumes from already-downloaded parts, so restarting
    /// the snapshot is cheap.
    func resumeDownload(_ config: ModelConfiguration) {
        guard case .paused = states[config] else { return }
        states[config] = .notDownloaded
        startDownload(config)
    }

    func deleteModel(_ config: ModelConfiguration) async {
        // Drop the engine's mmap'd file handle first — iOS only reclaims the
        // bytes when the last process unmaps the file.
        await ChatSession.shared.unloadEngine()
        HubCacheUtils.clear(config)
        refreshStates()
    }

    var totalCacheBytes: Int64 { HubCacheUtils.totalBytes }

    // MARK: - Background task

    private func beginBackgroundTask() {
        #if canImport(UIKit)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ModelDownload") { [weak self] in
            self?.endBackgroundTask()
        }
        #endif
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        #endif
    }
}

enum ModelDownloadError: LocalizedError {
    case fileMissing(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let name):
            return "Downloaded snapshot does not contain \(name)."
        }
    }
}
