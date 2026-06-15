//
//  ModelLibraryView.swift
//  SynapLink
//
//  Model download & storage management (NeuraLink ModelLibrary pattern):
//  one card per catalog entry, RAM gating with clear badges, select-to-use.
//

import SwiftUI

struct ModelLibraryView: View {
    @State private var manager = ModelDownloadManager.shared

    @State private var specialists = SpecialistManager.shared

    var body: some View {
        List {
            Section {
                ForEach(ModelConfiguration.allCases) { config in
                    ModelLibraryCard(config: config)
                }
            } header: {
                Text("Chat model")
            } footer: {
                Text("Models download once from Hugging Face and never leave your device. All chat runs fully offline.")
            }

            Section {
                ForEach(SpecialistModel.allCases) { model in
                    SpecialistCard(model: model)
                }
            } header: {
                Text("Add-on capabilities")
            } footer: {
                Text("Small helpers that add voice and photo input to any chat model — ideal where the full multimodal model is too large. Speech is transcribed and photos are described on-device, then handed to your chat model.")
            }

            Section("Storage") {
                LabeledContent("Total model storage",
                               value: ByteCountFormatter.string(
                                   fromByteCount: manager.totalCacheBytes, countStyle: .file))
                LabeledContent("This device",
                               value: String(format: "%.0f GB RAM", RuntimeProfile.physicalMemoryGB.rounded()))
            }
        }
        .scrollIndicators(.hidden)
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
    private var isSupported: Bool { config.isSupportedOnThisDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(config.deviceRecommendation)
                .font(.caption)
                .foregroundStyle(.secondary)
            stateRow
        }
        .padding(.vertical, 8)
        .opacity(isSupported ? 1 : 0.75)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: config.supportsMultimodal ? "sparkles.rectangle.stack" : "text.bubble")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(config.rawValue).font(.headline)
                Text("\(config.quantizationLabel) · \(config.estimatedSizeGB, specifier: "%.1f") GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            badge
        }
    }

    @ViewBuilder
    private var badge: some View {
        if !isSupported {
            badgeLabel("Won't run here", color: .red)
        } else if isSelected, case .ready = state {
            Label("In use", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if config.isRecommendedForThisDevice {
            badgeLabel("Recommended", color: .accentColor)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - State row

    @ViewBuilder
    private var stateRow: some View {
        if !isSupported {
            unsupportedRow
        } else {
            switch state {
            case .notDownloaded:
                Button {
                    manager.startDownload(config)
                } label: {
                    Label("Download · \(config.estimatedSizeGB, specifier: "%.1f") GB",
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isDownloadActive)

            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text("\(Int(progress * 100))% of \(config.estimatedSizeGB, specifier: "%.1f") GB")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Pause") { manager.pauseDownload() }
                            .font(.caption.weight(.semibold))
                    }
                }

            case .paused(let progress):
                HStack {
                    ProgressView(value: progress).tint(.orange)
                    Button("Resume") { manager.resumeDownload(config) }
                        .font(.caption.weight(.semibold))
                }

            case .ready:
                HStack {
                    if !isSelected {
                        Button("Use This Model") { selectModel() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Delete", role: .destructive) {
                        Task { await manager.deleteModel(config) }
                    }
                    .font(.caption)
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") { manager.startDownload(config) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Unsupported models can't be downloaded — but if one is already on
    /// disk (downloaded before RAM gating existed), offer to reclaim space.
    @ViewBuilder
    private var unsupportedRow: some View {
        if case .ready = state {
            HStack {
                Text("Downloaded but unusable on this device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete", role: .destructive) {
                    Task { await manager.deleteModel(config) }
                }
                .font(.caption.weight(.semibold))
            }
        } else {
            Text("Needs ≥\(Int(config.requiredRAMGB)) GB RAM — this device has \(Int(RuntimeProfile.physicalMemoryGB.rounded())) GB.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectModel() {
        guard manager.selectedConfig != config else { return }
        manager.selectedConfig = config
        // Different weights ⇒ the loaded engine is stale.
        Task { await ChatSession.shared.unloadEngine() }
    }
}

/// Download card for a sidecar specialist (Speech / Image Understanding).
struct SpecialistCard: View {
    let model: SpecialistModel

    @State private var manager = SpecialistManager.shared

    private var state: ModelDownloadState { manager.states[model] ?? .notDownloaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: model.iconName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.rawValue).font(.headline)
                    Text(model.tagline).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .ready = state {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            }
            stateRow
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var stateRow: some View {
        switch state {
        case .notDownloaded:
            Button {
                manager.startDownload(model)
            } label: {
                Label("Download · \(Int(model.estimatedSizeMB)) MB", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(manager.anyActive)

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                HStack {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause") { manager.pauseDownload() }.font(.caption)
                }
            }

        case .paused(let progress):
            HStack {
                ProgressView(value: progress).tint(.orange)
                Button("Resume") { manager.resumeDownload(model) }.font(.caption)
            }

        case .ready:
            HStack {
                Spacer()
                Button("Delete", role: .destructive) { manager.deleteModel(model) }
                    .font(.caption)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                Button("Retry") { manager.startDownload(model) }.buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    NavigationStack { ModelLibraryView() }
}
