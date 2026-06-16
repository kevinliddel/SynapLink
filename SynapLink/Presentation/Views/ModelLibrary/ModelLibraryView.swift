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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                    ForEach(SpecialistModel.allCases) { model in
                        SpecialistTile(model: model)
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowBackground(Color.clear)
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

/// Compact grid tile for a sidecar specialist (Speech / Vision / Image-gen).
/// Tapping runs the primary action for the current state (download / pause /
/// resume / retry); when installed, a context menu offers Delete.
struct SpecialistTile: View {
    let model: SpecialistModel

    @State private var manager = SpecialistManager.shared

    private var state: ModelDownloadState { manager.states[model] ?? .notDownloaded }
    private var installed: Bool { if case .ready = state { return true } else { return false } }
    private var supported: Bool { model.isSupportedOnThisDevice }

    var body: some View {
        VStack(spacing: 8) {
            icon
            Text(model.rawValue)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            statusLine
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 138)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(supported ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { primaryAction() }
        .contextMenu {
            if installed {
                Button(role: .destructive) {
                    manager.deleteModel(model)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: model.iconName)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background((installed ? Color.green : Color.accentColor).gradient, in: Circle())
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .notDownloaded:
            if supported {
                pill("\(Int(model.estimatedSizeMB)) MB", system: "arrow.down", tint: .accentColor)
            } else {
                Text("Needs \(Int(model.requiredRAMGB)) GB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))% · tap to pause")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

        case .paused(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress).tint(.orange)
                Text("Paused · tap to resume")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

        case .ready:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)

        case .failed:
            Label("Retry", systemImage: "arrow.clockwise")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private func pill(_ text: String, system: String, tint: Color) -> some View {
        Label(text, systemImage: system)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func primaryAction() {
        switch state {
        case .notDownloaded where supported, .failed:
            manager.startDownload(model)
        case .downloading:
            manager.pauseDownload()
        case .paused:
            manager.resumeDownload(model)
        default:
            break
        }
    }
}

#Preview {
    NavigationStack { ModelLibraryView() }
}
