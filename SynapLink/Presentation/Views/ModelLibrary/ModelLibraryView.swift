//
//  ModelLibraryView.swift
//  SynapLink
//
//  Model download & storage management (NeuraLink ModelLibrary pattern):
//  one card per catalog entry, total cache accounting, select-to-use.
//

import SwiftUI

struct ModelLibraryView: View {
    @State private var manager = ModelDownloadManager.shared

    var body: some View {
        List {
            Section {
                ForEach(ModelConfiguration.allCases) { config in
                    ModelLibraryCard(config: config)
                }
            } footer: {
                Text("Models download from Hugging Face once and never leave your device. Inference is fully offline.")
            }

            Section("Storage") {
                HStack {
                    Text("Total model storage")
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: manager.totalCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Model Library")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.refreshStates() }
    }
}

struct ModelLibraryCard: View {
    let config: ModelConfiguration

    @State private var manager = ModelDownloadManager.shared

    private var state: ModelDownloadState {
        manager.states[config] ?? .notDownloaded
    }

    private var isSelected: Bool { manager.selectedConfig == config }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(config.deviceRecommendation)
                .font(.caption)
                .foregroundStyle(.secondary)
            stateRow
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .ready = state {
                selectModel()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.rawValue).font(.headline)
                Text("\(config.quantizationLabel) · \(config.estimatedSizeGB, specifier: "%.1f") GB\(config.supportsMultimodal ? " · multimodal" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected, case .ready = state {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch state {
        case .notDownloaded:
            Button("Download") { manager.startDownload(config) }
                .buttonStyle(.bordered)

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                HStack {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause") { manager.pauseDownload() }
                        .font(.caption)
                }
            }

        case .paused(let progress):
            HStack {
                ProgressView(value: progress).tint(.orange)
                Button("Resume") { manager.resumeDownload(config) }
                    .font(.caption)
            }

        case .ready:
            HStack {
                if !isSelected {
                    Button("Use This Model") { selectModel() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Delete", role: .destructive) {
                    Task { await manager.deleteModel(config) }
                }
                .font(.caption)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") { manager.startDownload(config) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func selectModel() {
        guard manager.selectedConfig != config else { return }
        manager.selectedConfig = config
        // Different weights ⇒ the loaded engine is stale.
        Task { await ChatSession.shared.unloadEngine() }
    }
}

#Preview {
    NavigationStack { ModelLibraryView() }
}
