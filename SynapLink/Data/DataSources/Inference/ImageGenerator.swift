//
//  ImageGenerator.swift
//  SynapLink
//
//  On-demand text-to-image via stable-diffusion.cpp (experimental specialist).
//  Load → generate one image → unload, like the other specialists, so it only
//  occupies RAM while working. The caller unloads the main chat model first;
//  on the 4 GB tier SD's ~1.6 GB weights need essentially the whole budget.
//

import Foundation
import UIKit

enum ImageGenError: Error, LocalizedError {
    case modelNotInstalled
    case loadFailed
    case generationFailed
    case unsupportedDevice
    case insufficientMemory(availableMB: Int)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "The image model isn't installed. Download it in the Model Library."
        case .loadFailed: return "Failed to load the image model."
        case .generationFailed: return "Image generation failed."
        case .unsupportedDevice: return "This device doesn't have enough memory to generate images."
        case .insufficientMemory(let mb):
            return "Not enough free memory to generate an image right now (\(mb) MB available). "
                + "Close other apps and try again — image creation is experimental on this device."
        }
    }
}

/// One generation request's tunables, resolved per device tier.
struct ImageGenSettings {
    var width: Int32
    var height: Int32
    var steps: Int32
    var cfgScale: Float
    var sampleMethod: Int32   // sample_method_t raw (1 = EULER_A)
}

final class ImageGenerator: @unchecked Sendable {

    static let shared = ImageGenerator()

    private let queue = DispatchQueue(label: "com.dedicatus.synaplink.imagegen", qos: .userInitiated)

    private init() {}

    /// Generate an image for `prompt`. Returns JPEG data. Heavy and slow on the
    /// 4 GB tier (tens of seconds to minutes); callers show progress.
    func generate(prompt: String, negativePrompt: String = "") async throws -> Data {
        let spec = SpecialistModel.imageGen
        guard spec.isSupportedOnThisDevice else { throw ImageGenError.unsupportedDevice }
        guard let model = spec.modelURL() else { throw ImageGenError.modelNotInstalled }

        // SD 1.5 needs ~1.6 GB resident plus the diffusion working set. If the
        // jetsam headroom is already below that, attempting it would abort the
        // process (a native OOM can't be caught) — refuse with a clear message.
        let availableMB = MemoryFootprint.available() / (1024 * 1024)
        slog("image-gen requested — \(availableMB) MB free, gpu=\(RuntimeProfile.imageGenUsesGPU)", .info)
        if availableMB > 0 && availableMB < 1700 {
            slog("refusing image-gen: only \(availableMB) MB free", .warning)
            throw ImageGenError.insufficientMemory(availableMB: availableMB)
        }

        let taesd = spec.mmprojURL()  // TAESD reuses the catalog's "mmproj" slot
        let settings = RuntimeProfile.imageGenSettings
        slog("image-gen \(settings.width)x\(settings.height), \(settings.steps) steps", .info)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let started = DispatchTime.now()
                guard let handle = synap_sd_create(
                    model.path, taesd?.path, RuntimeProfile.specialistThreads,
                    RuntimeProfile.imageGenUsesGPU) else {
                    slog("SD model load failed", .error)
                    continuation.resume(throwing: ImageGenError.loadFailed)
                    return
                }
                defer { synap_sd_free(handle) }
                let loadSeconds = Self.elapsed(since: started)
                slog("SD model loaded in \(String(format: "%.1f", loadSeconds))s, generating…", .debug)

                var width: Int32 = 0
                var height: Int32 = 0
                let seed = Int64.random(in: 0...Int64(Int32.max))
                let rgb = prompt.withCString { cPrompt in
                    negativePrompt.withCString { cNeg in
                        synap_sd_generate(
                            handle, cPrompt, cNeg,
                            settings.width, settings.height, settings.steps,
                            settings.cfgScale, settings.sampleMethod, seed,
                            &width, &height)
                    }
                }
                guard let rgb, width > 0, height > 0 else {
                    continuation.resume(throwing: ImageGenError.generationFailed)
                    return
                }
                defer { synap_sd_free_rgb(rgb) }

                guard let jpeg = Self.jpeg(fromRGB: rgb, width: Int(width), height: Int(height)) else {
                    slog("SD image encode failed", .error)
                    continuation.resume(throwing: ImageGenError.generationFailed)
                    return
                }
                let totalSeconds = Self.elapsed(since: started)
                slog("image generated: \(width)x\(height), \(jpeg.count / 1024) KB in "
                    + "\(String(format: "%.1f", totalSeconds))s (load \(String(format: "%.1f", loadSeconds))s, "
                    + "\(settings.steps) steps)", .info)
                continuation.resume(returning: jpeg)
            }
        }
    }

    /// Wall-clock seconds since `start` (monotonic).
    private static func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Pack tightly-packed RGB888 into a JPEG.
    private static func jpeg(fromRGB rgb: UnsafePointer<UInt8>, width: Int, height: Int) -> Data? {
        let count = width * height * 3
        let data = Data(bytes: rgb, count: count)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }
}
