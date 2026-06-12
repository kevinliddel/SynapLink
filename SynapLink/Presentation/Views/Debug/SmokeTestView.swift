//
//  SmokeTestView.swift
//  SynapLink
//
//  Phase 0 smoke-test screen. Side-load GGUF files into the app's Documents
//  folder via Finder (file sharing is enabled), pick a model, load, benchmark.
//

import SwiftUI

struct SmokeTestView: View {
    @State private var viewModel = SmokeTestViewModel()

    var body: some View {
        Form {
            modelSection
            controlSection
            if let result = viewModel.result, viewModel.loadState != .unloaded {
                resultSection(result)
            }
            outputSection
        }
        .navigationTitle("Smoke Test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refreshModels()
            viewModel.autoRunIfRequested()
        }
    }

    // MARK: - Sections

    private var modelSection: some View {
        Section("Model (Documents/*.gguf)") {
            if viewModel.availableModels.isEmpty {
                Text("No GGUF files found. Copy a model into the app's Documents folder via Finder → iPhone → Files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $viewModel.selectedModel) {
                    Text("None").tag(URL?.none)
                    ForEach(viewModel.availableModels, id: \.self) { url in
                        Text(url.lastPathComponent).tag(URL?.some(url))
                    }
                }
                Picker("mmproj", selection: $viewModel.selectedMMProj) {
                    Text("None (text-only)").tag(URL?.none)
                    ForEach(viewModel.availableModels, id: \.self) { url in
                        Text(url.lastPathComponent).tag(URL?.some(url))
                    }
                }
            }
            Button("Rescan") { viewModel.refreshModels() }
        }
    }

    private var controlSection: some View {
        Section("Run") {
            switch viewModel.loadState {
            case .unloaded:
                Button("Load Model") {
                    Task { await viewModel.loadModel() }
                }
                .disabled(viewModel.selectedModel == nil)
            case .loading:
                HStack {
                    ProgressView()
                    Text("Loading…").padding(.leading, 8)
                }
            case .loaded(let description):
                Text(description)
                    .font(.caption.monospaced())
                TextField("Prompt", text: $viewModel.prompt, axis: .vertical)
                if viewModel.isGenerating {
                    Button("Stop", role: .destructive) { viewModel.stopGeneration() }
                } else {
                    Button("Run Benchmark") {
                        Task { await viewModel.runBenchmark() }
                    }
                    Button("Unload", role: .destructive) {
                        Task { await viewModel.unloadModel() }
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again") {
                    Task { await viewModel.loadModel() }
                }
            }
        }
    }

    private func resultSection(_ result: SmokeTestViewModel.BenchmarkResult) -> some View {
        Section("Exit gate: ≥7 tok/s, peak <1.8 GB") {
            row("Load time", String(format: "%.1f s", result.loadSeconds))
            if let caps = result.capabilities {
                row("Vision / Audio",
                    "\(caps.hasVision ? "✓" : "–") / \(caps.hasAudio ? "✓" : "–")")
                row("Context", "\(caps.nCtx) tok")
            }
            if result.stats.decodeTokens > 0 {
                row("TTFT", String(format: "%.2f s", result.timeToFirstTokenSeconds))
                row("Prefill", String(format: "%d tok @ %.0f tok/s (%d reused)",
                                      result.stats.prefillNew,
                                      result.stats.prefillTokensPerSecond,
                                      result.stats.prefillReused))
                gateRow("Decode",
                        String(format: "%d tok @ %.1f tok/s",
                               result.stats.decodeTokens,
                               result.stats.decodeTokensPerSecond),
                        passed: result.passesTokensPerSecond)
            }
            if result.peakFootprint > 0 {
                gateRow("Peak footprint",
                        MemoryFootprint.formatted(result.peakFootprint),
                        passed: result.passesMemory)
            }
            if result.minAvailable != .max {
                row("Min jetsam headroom",
                    MemoryFootprint.formatted(UInt64(max(0, result.minAvailable))))
            }
            row("Live footprint", MemoryFootprint.formatted(viewModel.liveFootprint))
        }
    }

    private var outputSection: some View {
        Section("Output") {
            if viewModel.output.isEmpty {
                Text(viewModel.isGenerating ? "Generating…" : "—")
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.output)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Rows

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).font(.callout.monospacedDigit())
        }
    }

    private func gateRow(_ label: String, _ value: String, passed: Bool) -> some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).font(.callout.monospacedDigit())
        }
    }
}

#Preview {
    SmokeTestView()
}
