//
//  SmokeTestViewModel.swift
//  SynapLink
//
//  Performance test backing state. Benchmarks the models the app actually
//  has: installed Model Library entries first, with Documents side-loads as
//  extra sources (that's also how CI injects its tiny test model — see
//  scripts/simulator-smoketest.sh and autoRunIfRequested()).
//

import Foundation
import Observation

/// Something we can benchmark: an installed catalog model or a side-loaded file.
struct BenchmarkSource: Identifiable, Hashable {
    let id: String
    let displayName: String
    let detail: String
    let modelPath: String
    let mmprojPath: String?
}

@MainActor
@Observable
final class SmokeTestViewModel {

    enum Stage: Equatable {
        case idle
        case loadingModel
        case generating
        case done
        case failed(String)
    }

    struct BenchmarkResult {
        var loadSeconds: Double = 0
        var timeToFirstTokenSeconds: Double = 0
        var stats = GenerationStats()
        var peakFootprint: UInt64 = 0
        var minAvailable: Int = .max
        var output = ""

        /// Phase 0 exit-gate targets (PLAN.md): ≥7 tok/s, peak <1.8 GB.
        var passesTokensPerSecond: Bool { stats.decodeTokensPerSecond >= 7 }
        var passesMemory: Bool { peakFootprint > 0 && peakFootprint < 1_800_000_000 }
        var passesAll: Bool { passesTokensPerSecond && passesMemory }

        var speedVerdict: String {
            let tps = stats.decodeTokensPerSecond
            if tps >= 15 { return "Feels instant" }
            if tps >= 7 { return "Comfortable for daily use" }
            return "Below the smooth-chat target"
        }
    }

    private(set) var sources: [BenchmarkSource] = []
    var selectedSource: BenchmarkSource?

    private(set) var stage: Stage = .idle
    private(set) var result: BenchmarkResult?
    private(set) var liveFootprint: UInt64 = 0

    var isRunning: Bool { stage == .loadingModel || stage == .generating }

    @ObservationIgnored private let engine = InferenceEngine.shared
    @ObservationIgnored private var memorySampler: Task<Void, Never>?

    private static let benchmarkPrompt = "Explain in three sentences why the sky is blue."

    // MARK: - Sources

    /// Installed Model Library entries first (the model the user actually
    /// chats with is preselected), then any GGUF side-loaded into Documents.
    func refreshSources() {
        var found: [BenchmarkSource] = []

        for config in ModelConfiguration.allCases
        where config.isInstalled && config.isSupportedOnThisDevice {
            if let url = config.modelURL() {
                found.append(BenchmarkSource(
                    id: "installed:\(config.rawValue)",
                    displayName: config.rawValue,
                    detail: "\(config.quantizationLabel) · installed",
                    modelPath: url.path,
                    mmprojPath: config.mmprojURL()?.path))
            }
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let sideMMProj = files.first { $0.lastPathComponent.lowercased().hasPrefix("mmproj") }
        for file in files where !file.lastPathComponent.lowercased().hasPrefix("mmproj") {
            found.append(BenchmarkSource(
                id: "file:\(file.lastPathComponent)",
                displayName: file.deletingPathExtension().lastPathComponent,
                detail: "side-loaded file",
                modelPath: file.path,
                mmprojPath: sideMMProj?.path))
        }

        sources = found
        if selectedSource == nil || !found.contains(where: { $0.id == selectedSource?.id }) {
            // Prefer the model the user actually chats with.
            let current = ModelDownloadManager.shared.selectedConfig
            selectedSource = found.first { $0.id == "installed:\(current.rawValue)" } ?? found.first
        }
    }

    // MARK: - Run

    func run() async {
        guard let source = selectedSource, !isRunning else { return }
        stage = .loadingModel
        result = nil
        var benchmark = BenchmarkResult()
        startMemorySampling()

        // The chat may hold the engine; a fresh load measures real load time.
        await ChatSession.shared.unloadEngine()

        do {
            let loadStart = Date()
            let params = RuntimeProfile.engineParams(
                modelPath: source.modelPath, mmprojPath: source.mmprojPath)
            _ = try await engine.load(params)
            benchmark.loadSeconds = Date().timeIntervalSince(loadStart)

            stage = .generating
            let prompt = try await engine.applyChatTemplate([
                ChatMessage(role: "user", content: Self.benchmarkPrompt)
            ])
            let genStart = Date()
            var firstToken: Date?
            for try await piece in engine.generate(prompt: prompt, maxNewTokens: 128) {
                if firstToken == nil { firstToken = Date() }
                benchmark.output += piece
            }
            benchmark.timeToFirstTokenSeconds = (firstToken ?? genStart).timeIntervalSince(genStart)
            benchmark.stats = await engine.stats()

            stopMemorySampling(into: &benchmark)
            result = benchmark
            stage = benchmark.stats.decodeTokens > 0 ? .done : .failed("The model produced no output.")
        } catch {
            stopMemorySampling(into: &benchmark)
            result = benchmark
            stage = .failed(error.localizedDescription)
        }

        // The benchmark's model may differ from the chat's selection; the
        // chat reloads its own model lazily on the next turn.
        await engine.unload()
    }

    // MARK: - Headless CI mode

    /// `--auto-benchmark` (scripts/simulator-smoketest.sh) runs hands-free
    /// and drops a verdict into Documents/benchmark-result.json. Functional
    /// gate only — CI simulators never score performance.
    func autoRunIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--auto-benchmark") else { return }
        Task {
            refreshSources()
            await run()
            writeBenchmarkResultFile()
        }
    }

    private func writeBenchmarkResultFile() {
        let status: String
        switch stage {
        case .done: status = "ok"
        case .failed where result?.loadSeconds == 0: status = "load_failed"
        default: status = "generate_failed"
        }
        let payload: [String: Any] = [
            "status": status,
            "loadSeconds": result?.loadSeconds ?? 0,
            "ttftSeconds": result?.timeToFirstTokenSeconds ?? 0,
            "decodeTokens": result?.stats.decodeTokens ?? 0,
            "decodeTokensPerSecond": result?.stats.decodeTokensPerSecond ?? 0,
            "prefillReused": result?.stats.prefillReused ?? 0,
            "peakFootprintBytes": result?.peakFootprint ?? 0,
            "output": result?.output ?? ""
        ]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("benchmark-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Memory sampling

    private func startMemorySampling() {
        memorySampler?.cancel()
        liveFootprint = MemoryFootprint.footprint() ?? 0
        memorySampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.liveFootprint = max(self.liveFootprint, MemoryFootprint.footprint() ?? 0)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopMemorySampling(into benchmark: inout BenchmarkResult) {
        memorySampler?.cancel()
        memorySampler = nil
        benchmark.peakFootprint = max(liveFootprint, MemoryFootprint.footprint() ?? 0)
        benchmark.minAvailable = min(benchmark.minAvailable, MemoryFootprint.available())
    }
}
