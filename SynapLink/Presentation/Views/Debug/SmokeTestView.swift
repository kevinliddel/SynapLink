//
//  SmokeTestView.swift
//  SynapLink
//
//  Performance test, human edition: pick the installed model (preselected to
//  the one you chat with), run, and read the verdict in plain language —
//  with the raw numbers tucked into a details section.
//

import SwiftUI

struct SmokeTestView: View {
    @State private var viewModel = SmokeTestViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modelCard
                runButton
                if viewModel.isRunning {
                    progressCard
                }
                if let result = viewModel.result, viewModel.stage == .done {
                    verdictCard(result)
                    numbersCard(result)
                    sampleReply(result)
                }
                if case .failed(let message) = viewModel.stage {
                    failureCard(message)
                }
                Text("Everything runs on this device — the test never uses the network.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Performance Test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refreshSources()
            viewModel.autoRunIfRequested()
        }
    }

    // MARK: - Model selection

    private var modelCard: some View {
        card {
            if viewModel.sources.isEmpty {
                Label("No model available — download one in the Model Library first.",
                      systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.selectedSource?.displayName ?? "—")
                            .font(.headline)
                        Text(viewModel.selectedSource?.detail ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.sources.count > 1 {
                        Menu("Change") {
                            ForEach(viewModel.sources) { source in
                                Button(source.displayName) {
                                    viewModel.selectedSource = source
                                }
                            }
                        }
                        .font(.callout)
                        .disabled(viewModel.isRunning)
                    }
                }
            }
        }
    }

    private var runButton: some View {
        Button {
            Task { await viewModel.run() }
        } label: {
            Label(viewModel.result == nil ? "Run Performance Test" : "Run Again",
                  systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.selectedSource == nil || viewModel.isRunning)
    }

    // MARK: - Progress

    private var progressCard: some View {
        card {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.stage == .loadingModel ? "Loading the model…" : "Generating a reply…")
                        .font(.callout.weight(.medium))
                    Text("Memory in use: \(MemoryFootprint.formatted(viewModel.liveFootprint))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
        }
    }

    // MARK: - Results

    private func verdictCard(_ result: SmokeTestViewModel.BenchmarkResult) -> some View {
        card {
            VStack(spacing: 8) {
                Text(String(format: "%.1f", result.stats.decodeTokensPerSecond))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                + Text(" tokens/s")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Label(result.speedVerdict,
                      systemImage: result.passesTokensPerSecond ? "checkmark.seal.fill" : "tortoise.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(result.passesTokensPerSecond ? .green : .orange)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func numbersCard(_ result: SmokeTestViewModel.BenchmarkResult) -> some View {
        card {
            VStack(spacing: 10) {
                row("First word appears", String(format: "%.1f s", result.timeToFirstTokenSeconds))
                row("Model load time", String(format: "%.1f s", result.loadSeconds))
                VStack(alignment: .leading, spacing: 4) {
                    row("Peak memory", MemoryFootprint.formatted(result.peakFootprint),
                        ok: result.passesMemory)
                    Gauge(value: min(Double(result.peakFootprint), 2_100_000_000), in: 0...2_100_000_000) {
                        EmptyView()
                    }
                    .tint(result.passesMemory ? .green : .red)
                    Text("Budget: stay under 1.8 GB of the ~2.1 GB system limit")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if result.minAvailable != .max && result.minAvailable > 0 {
                    row("Memory headroom left",
                        MemoryFootprint.formatted(UInt64(max(0, result.minAvailable))))
                }
            }
        }
    }

    private func sampleReply(_ result: SmokeTestViewModel.BenchmarkResult) -> some View {
        card {
            DisclosureGroup {
                Text(result.output)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .textSelection(.enabled)
            } label: {
                Label("What the model wrote", systemImage: "text.quote")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func failureCard(_ message: String) -> some View {
        card {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Bits

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ label: String, _ value: String, ok: Bool? = nil) -> some View {
        HStack {
            if let ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red)
                    .font(.callout)
            }
            Text(label).font(.callout)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { SmokeTestView() }
}
