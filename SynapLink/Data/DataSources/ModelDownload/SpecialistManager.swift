//
//  SpecialistManager.swift
//  SynapLink
//
//  Download/installed-state tracking for the sidecar specialist models,
//  mirroring ModelDownloadManager but for SpecialistModel. Uses the same
//  Hugging Face Hub snapshot mechanism (only the needed files) into the
//  shared Application Support/hub cache.
//

import Foundation
import Hub
import Observation

@MainActor
@Observable
final class SpecialistManager {

    static let shared = SpecialistManager()

    private(set) var states: [SpecialistModel: ModelDownloadState] = [:]

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeModel: SpecialistModel?

    private init() {
        refreshStates()
    }

    func refreshStates() {
        for model in SpecialistModel.allCases where model != activeModel {
            states[model] = model.isInstalled ? .ready : .notDownloaded
        }
    }

    func isInstalled(_ model: SpecialistModel) -> Bool { states[model] == .ready }

    var anyActive: Bool {
        states.values.contains { if case .downloading = $0 { return true } else { return false } }
    }

    func startDownload(_ model: SpecialistModel) {
        guard activeTask == nil, states[model] != .ready, model.isSupportedOnThisDevice else { return }
        activeModel = model
        states[model] = .downloading(progress: 0)

        activeTask = Task { [weak self] in
            do {
                try await Self.download(model) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeModel == model else { return }
                        self.states[model] = .downloading(progress: progress)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.states[model] = model.isInstalled ? .ready : .failed("File missing after download")
            } catch is CancellationError {
                // state already set by pause/cancel
            } catch {
                if !Task.isCancelled { self?.states[model] = .failed(error.localizedDescription) }
            }
            self?.activeTask = nil
            self?.activeModel = nil
        }
    }

    func pauseDownload() {
        guard let model = activeModel, case .downloading(let progress) = states[model] else { return }
        activeTask?.cancel()
        activeTask = nil
        activeModel = nil
        states[model] = .paused(progress: progress)
    }

    func resumeDownload(_ model: SpecialistModel) {
        guard case .paused = states[model] else { return }
        states[model] = .notDownloaded
        startDownload(model)
    }

    func deleteModel(_ model: SpecialistModel) {
        try? FileManager.default.removeItem(at: model.cacheURL)
        refreshStates()
    }

    private static func download(_ model: SpecialistModel,
                                 progressHandler: @escaping (Double) -> Void) async throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let api = HubApi(downloadBase: appSupport)
        let repo = Hub.Repo(id: model.repoID)
        let snapshotDir = try await api.snapshot(from: repo, matching: model.downloadFilenames) { progress in
            progressHandler(progress.fractionCompleted * 0.97)
        }

        func locate(_ filename: String) throws -> URL {
            let direct = snapshotDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: snapshotDir, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                let candidate = entry.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            throw ModelDownloadError.fileMissing(filename)
        }

        let modelURL = try locate(model.filename)
        let mmprojURL = try model.mmprojFilename.map { try locate($0) }
        model.persistPaths(modelURL: modelURL, mmprojURL: mmprojURL)
        progressHandler(1.0)
    }
}
