//
//  SmokeTestViewModel.swift
//  SynapLink
//
//  Phase 0 exit-gate harness: load a GGUF from Documents (side-loaded via
//  Finder file sharing), run a fixed benchmark prompt, and report decode
//  tok/s + peak phys_footprint against the targets (≥7 tok/s, <1.8 GB peak).
//

import Foundation
import Observation

@MainActor
@Observable
final class SmokeTestViewModel {

    enum LoadState: Equatable {
        case unloaded
        case loading
        case loaded(description: String)
        case failed(message: String)
    }

    struct BenchmarkResult {
        var loadSeconds: Double = 0
        var timeToFirstTokenSeconds: Double = 0
        var stats = GenerationStats()
        var peakFootprint: UInt64 = 0
        var minAvailable: Int = .max
        var capabilities: EngineCapabilities?

        /// Phase 0 exit gate: ≥7 tok/s, peak <1.8 GB.
        var passesTokensPerSecond: Bool { stats.decodeTokensPerSecond >= 7 }
        var passesMemory: Bool { peakFootprint > 0 && peakFootprint < 1_800_000_000 }
    }

    // Model files discovered in Documents.
    private(set) var availableModels: [URL] = []
    var selectedModel: URL?
    var selectedMMProj: URL?   // optional; nil = text-only smoke test

    private(set) var loadState: LoadState = .unloaded
    private(set) var isGenerating = false
    private(set) var output = ""
    private(set) var result: BenchmarkResult?
    private(set) var liveFootprint: UInt64 = 0

    var prompt = "Explain in three sentences why the sky is blue."
    var maxNewTokens: Int32 = 128

    private let engine = InferenceEngine.shared
    private var memorySampler: Task<Void, Never>?

    // MARK: - Model discovery

    func refreshModels() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil)) ?? []
        availableModels = files
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Sensible auto-pick: first non-mmproj GGUF as model, first mmproj-* as projector.
        if selectedModel == nil {
            selectedModel = availableModels.first {
                !$0.lastPathComponent.lowercased().hasPrefix("mmproj")
            }
        }
        if selectedMMProj == nil {
            selectedMMProj = availableModels.first {
                $0.lastPathComponent.lowercased().hasPrefix("mmproj")
            }
        }
    }

    // MARK: - Lifecycle

    func loadModel() async {
        guard let model = selectedModel, loadState != .loading else { return }
        loadState = .loading
        result = nil
        output = ""

        var params = EngineParams(modelPath: model.path)
        params.mmprojPath = selectedMMProj?.path

        let t0 = Date()
        do {
            let caps = try await engine.load(params)
            var r = BenchmarkResult()
            r.loadSeconds = Date().timeIntervalSince(t0)
            r.capabilities = caps
            result = r
            loadState = .loaded(description: caps.modelDescription)
        } catch {
            loadState = .failed(message: error.localizedDescription)
        }
    }

    func unloadModel() async {
        engine.cancel()
        await engine.unload()
        loadState = .unloaded
        result = nil
        output = ""
    }

    // MARK: - Benchmark

    func runBenchmark() async {
        guard case .loaded = loadState, !isGenerating else { return }
        isGenerating = true
        output = ""
        startMemorySampling()

        var r = result ?? BenchmarkResult()
        r.stats = GenerationStats()
        r.timeToFirstTokenSeconds = 0
        r.peakFootprint = MemoryFootprint.footprint() ?? 0
        r.minAvailable = MemoryFootprint.available()
        result = r

        do {
            let templated = try await engine.applyChatTemplate([
                ChatMessage(role: "user", content: prompt)
            ])
            let t0 = Date()
            var firstToken: Date?
            for try await piece in engine.generate(prompt: templated, maxNewTokens: maxNewTokens) {
                if firstToken == nil { firstToken = Date() }
                output += piece
            }
            var updated = result ?? r
            updated.timeToFirstTokenSeconds = (firstToken ?? t0).timeIntervalSince(t0)
            updated.stats = await engine.stats()
            result = updated
        } catch {
            output += "\n\n⚠️ \(error.localizedDescription)"
        }

        stopMemorySampling()
        isGenerating = false
    }

    func stopGeneration() {
        engine.cancel()
    }

    // MARK: - Memory sampling

    private func startMemorySampling() {
        memorySampler?.cancel()
        memorySampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let footprint = MemoryFootprint.footprint() ?? 0
                let available = MemoryFootprint.available()
                self.liveFootprint = footprint
                if var r = self.result {
                    r.peakFootprint = max(r.peakFootprint, footprint)
                    r.minAvailable = min(r.minAvailable, available)
                    self.result = r
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopMemorySampling() {
        memorySampler?.cancel()
        memorySampler = nil
        liveFootprint = MemoryFootprint.footprint() ?? 0
    }
}
