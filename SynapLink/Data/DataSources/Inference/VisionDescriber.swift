//
//  VisionDescriber.swift
//  SynapLink
//
//  On-demand image captioning via SmolVLM (the vision specialist in the
//  sidecar pipeline). Runs in its OWN transient engine so the main chat
//  model stays resident; the C backend is refcounted to allow both. The
//  resulting description is fed back to the main model as context.
//

import Foundation

enum VisionError: Error, LocalizedError {
    case modelNotInstalled
    case loadFailed
    case describeFailed

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "The vision model isn't installed. Download it in the Model Library."
        case .loadFailed: return "Failed to load the vision model."
        case .describeFailed: return "Couldn't analyze the image."
        }
    }
}

final class VisionDescriber: @unchecked Sendable {

    static let shared = VisionDescriber()

    /// Its own engine instance — coexists with InferenceEngine.shared.
    private let engine = InferenceEngine(label: "com.dedicatus.synaplink.vision")

    private static let describePrompt =
        "Describe this image in detail: objects, people, text, setting, and notable details."

    private init() {}

    /// Load SmolVLM, describe the image, unload. Returns the description text.
    func describe(imageData: Data,
                  userQuestion: String? = nil) async throws -> String {
        let vision = SpecialistModel.vision
        guard let model = vision.modelURL(), let mmproj = vision.mmprojURL() else {
            throw VisionError.modelNotInstalled
        }

        let params = RuntimeProfile.visionEngineParams(modelPath: model.path, mmprojPath: mmproj.path)
        do {
            _ = try await engine.load(params)
        } catch {
            throw VisionError.loadFailed
        }
        defer { Task { await engine.unload() } }

        let question = userQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = (question?.isEmpty == false) ? question! : Self.describePrompt
        let userContent = InferenceEngine.mediaMarker + ask

        do {
            let prompt = try await engine.applyChatTemplate([
                ChatMessage(role: "user", content: userContent)
            ])
            var description = ""
            for try await piece in engine.generate(
                prompt: prompt, media: [imageData], maxNewTokens: 200) {
                description += piece
            }
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw VisionError.describeFailed }
            return trimmed
        } catch let error as VisionError {
            throw error
        } catch {
            throw VisionError.describeFailed
        }
    }
}
