//
//  ModelCatalog.swift
//  SynapLink
//
//  The model registry: which GGUFs we ship, where they live on Hugging Face,
//  and how their local paths resolve. Mirrors NeuraLink's ModelConfiguration
//  + ModelAccess pattern, collapsed into one generic catalog.
//
//  NOTE on sizes: PLAN.md §1 budgeted ~1.3 GB for "E2B Q4" weights, but the
//  real Gemma 4 E2B GGUFs are ~3.0–3.1 GB (E2B = 5B raw params, 2B *active*).
//  Whether that fits the iPhone 11 jetsam limit is an open device-test
//  question; Gemma 3 1B is the guaranteed-fit 4 GB-tier fallback so the
//  Phase 1 exit gate stays testable on the baseline device.
//

import Foundation

enum ModelConfiguration: String, CaseIterable, Identifiable, Sendable {
    case gemma4E2B = "Gemma 4 E2B"
    case gemma4E2BQ40 = "Gemma 4 E2B (Q4_0)"
    case gemma3_1B = "Gemma 3 1B"

    var id: String { rawValue }

    var repoID: String {
        switch self {
        case .gemma4E2B, .gemma4E2BQ40: return "unsloth/gemma-4-E2B-it-GGUF"
        case .gemma3_1B: return "ggml-org/gemma-3-1b-it-GGUF"
        }
    }

    var filename: String {
        switch self {
        case .gemma4E2B: return "gemma-4-E2B-it-Q4_K_M.gguf"
        case .gemma4E2BQ40: return "gemma-4-E2B-it-Q4_0.gguf"
        case .gemma3_1B: return "gemma-3-1b-it-Q4_K_M.gguf"
        }
    }

    /// Multimodal projector file in the same repo; nil = text-only model.
    var mmprojFilename: String? {
        switch self {
        case .gemma4E2B, .gemma4E2BQ40: return "mmproj-F16.gguf"
        case .gemma3_1B: return nil
        }
    }

    var estimatedSizeGB: Double {
        switch self {
        case .gemma4E2B: return 3.11 + 0.99
        case .gemma4E2BQ40: return 3.04 + 0.99
        case .gemma3_1B: return 0.81
        }
    }

    var quantizationLabel: String {
        switch self {
        case .gemma4E2B, .gemma3_1B: return "Q4_K_M"
        case .gemma4E2BQ40: return "Q4_0"
        }
    }

    var supportsMultimodal: Bool { mmprojFilename != nil }

    /// Minimum physical RAM to run this model. E2B weights are ~2.9 GB —
    /// on the iPhone 11 (4 GB) Metal allocates past the A13's ~2.7 GB
    /// working-set limit and jetsam kills the app, so it is hard-gated.
    var requiredRAMGB: Double {
        switch self {
        case .gemma4E2B, .gemma4E2BQ40: return 6.0
        case .gemma3_1B: return 0
        }
    }

    /// `physicalMemory` under-reports (a "4 GB" device shows ~3.7 GB), so
    /// compare with half a GB of slack.
    var isSupportedOnThisDevice: Bool {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return gb + 0.5 >= requiredRAMGB
    }

    var isRecommendedForThisDevice: Bool { self == .defaultConfigForCurrentDevice() }

    var deviceRecommendation: String {
        switch self {
        case .gemma4E2B: return "Vision + audio input · needs ≥6 GB RAM"
        case .gemma4E2BQ40: return "Faster on older GPUs · needs ≥6 GB RAM"
        case .gemma3_1B: return "Text only · runs on every supported device"
        }
    }

    /// HF Hub cache directory slug ("models--{org}--{repo}").
    var hubSlug: String {
        "models--" + repoID.replacingOccurrences(of: "/", with: "--")
    }

    var pathKey: String { "SynapLinkModelPath_\(hubSlug)_\(filename)" }
    var mmprojPathKey: String { "SynapLinkMMProjPath_\(hubSlug)" }

    /// 4 GB devices get the model that provably fits; everything bigger gets
    /// the principal multimodal model (NeuraLink's RAM-tier approach).
    static func defaultConfigForCurrentDevice() -> ModelConfiguration {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return gb >= 5.0 ? .gemma4E2B : .gemma3_1B
    }

    // MARK: - Local path resolution

    /// Resolve the model file on disk: persisted path first (validated
    /// against the current filename so quant changes force a re-download),
    /// then a scan of the Hub snapshot cache.
    func modelURL() -> URL? {
        resolve(filename: filename, key: pathKey)
    }

    func mmprojURL() -> URL? {
        guard let mmprojFilename else { return nil }
        return resolve(filename: mmprojFilename, key: mmprojPathKey)
    }

    var isInstalled: Bool {
        modelURL() != nil && (mmprojFilename == nil || mmprojURL() != nil)
    }

    private func resolve(filename: String, key: String) -> URL? {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let relative = UserDefaults.standard.string(forKey: key) {
            let url = appSupport.appendingPathComponent(relative)
            if url.lastPathComponent == filename,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return scanHubCache(for: filename, persistTo: key)
    }

    private func scanHubCache(for filename: String, persistTo key: String) -> URL? {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let snapshots = appSupport.appendingPathComponent("hub/\(hubSlug)/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return nil }

        for snapshot in entries.sorted(by: { $0.path > $1.path }) {
            let candidate = snapshot.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                persistPath(candidate, key: key)
                return candidate
            }
        }
        return nil
    }

    func persistPath(_ url: URL, key: String) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let relative = url.path.replacingOccurrences(of: appSupport.path + "/", with: "")
        UserDefaults.standard.set(relative, forKey: key)
    }

    func clearPersistedPaths() {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: mmprojPathKey)
    }
}
