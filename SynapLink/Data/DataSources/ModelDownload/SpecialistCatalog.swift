//
//  SpecialistCatalog.swift
//  SynapLink
//
//  The sidecar specialist models: small, single-purpose models that feed the
//  main chat model (PLAN.md §2 split-pipeline fallback). They give the
//  4 GB iPhone 11 tier real audio + image input, which the omni Gemma 4 E2B
//  can't provide there.
//
//    • whisper  — speech → text (whisper.cpp, ggml-base.bin, ~142 MB)
//    • vision   — image → description (SmolVLM-500M via the mtmd path, ~550 MB)
//
//  Both download through the same Hugging Face Hub mechanism as the main
//  catalog and resolve out of the shared Application Support/hub cache.
//

import Foundation

enum SpecialistModel: String, CaseIterable, Identifiable {
    case whisper = "Speech to Text"
    case vision = "Image Understanding"
    case imageGen = "Image Creation"

    var id: String { rawValue }

    var repoID: String {
        switch self {
        case .whisper: return "ggerganov/whisper.cpp"
        case .vision: return "ggml-org/SmolVLM-500M-Instruct-GGUF"
        case .imageGen: return "second-state/stable-diffusion-v1-5-GGUF"
        }
    }

    /// Primary model file (whisper .bin / VLM .gguf / SD checkpoint .gguf).
    var filename: String {
        switch self {
        case .whisper: return "ggml-base.bin"
        case .vision: return "SmolVLM-500M-Instruct-Q8_0.gguf"
        case .imageGen: return "stable-diffusion-v1-5-pruned-emaonly-Q4_0.gguf"
        }
    }

    /// Vision projector (vision) / TAESD tiny VAE slot (image-gen, unused for now).
    var mmprojFilename: String? {
        switch self {
        case .whisper, .imageGen: return nil
        case .vision: return "mmproj-SmolVLM-500M-Instruct-Q8_0.gguf"
        }
    }

    var downloadFilenames: [String] {
        [filename] + (mmprojFilename.map { [$0] } ?? [])
    }

    var estimatedSizeMB: Double {
        switch self {
        case .whisper: return 142
        case .vision: return 437 + 109
        case .imageGen: return 1567
        }
    }

    var iconName: String {
        switch self {
        case .whisper: return "waveform"
        case .vision: return "photo"
        case .imageGen: return "wand.and.stars"
        }
    }

    var tagline: String {
        switch self {
        case .whisper: return "Speak instead of type — transcribed on-device."
        case .vision: return "Attach a photo and ask about it."
        case .imageGen: return "Create images from a text prompt."
        }
    }

    /// Experimental on the 4 GB tier: heavy and slow, may strain memory.
    var isExperimental: Bool { self == .imageGen }

    /// whisper/vision are tiny and fit any supported device. Image generation
    /// is ~1.6 GB resident during diffusion — gate it to ≈4 GB+ and warn it's
    /// experimental there (the main chat model is unloaded while it runs).
    var requiredRAMGB: Double {
        switch self {
        case .whisper, .vision: return 0
        case .imageGen: return 3.5
        }
    }

    var isSupportedOnThisDevice: Bool {
        RuntimeProfile.physicalMemoryGB + 0.5 >= requiredRAMGB
    }

    // MARK: - Local path resolution (shared hub cache)

    private var hubSlug: String {
        "models--" + repoID.replacingOccurrences(of: "/", with: "--")
    }

    private var pathKey: String { "SynapLinkSpecialistPath_\(hubSlug)_\(filename)" }
    private var mmprojPathKey: String { "SynapLinkSpecialistMMProj_\(hubSlug)" }

    func modelURL() -> URL? { resolve(filename: filename, key: pathKey) }

    func mmprojURL() -> URL? {
        guard let mmprojFilename else { return nil }
        return resolve(filename: mmprojFilename, key: mmprojPathKey)
    }

    var isInstalled: Bool {
        modelURL() != nil && (mmprojFilename == nil || mmprojURL() != nil)
    }

    private func resolve(filename: String, key: String) -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let relative = UserDefaults.standard.string(forKey: key) {
            let url = appSupport.appendingPathComponent(relative)
            if url.lastPathComponent == filename, FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        UserDefaults.standard.set(url.path.replacingOccurrences(of: appSupport.path + "/", with: ""), forKey: key)
    }

    func persistPaths(modelURL: URL, mmprojURL: URL?) {
        persistPath(modelURL, key: pathKey)
        if let mmprojURL { persistPath(mmprojURL, key: mmprojPathKey) }
    }

    var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hub/\(hubSlug)")
    }
}
