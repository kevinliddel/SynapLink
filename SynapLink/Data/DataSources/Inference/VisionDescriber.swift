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

    private static let describePrompt = """
    Look at this image and describe it thoroughly in 4 to 6 complete sentences. \
    Cover: the main subject and what is happening; people (appearance, clothing, \
    expressions, what they are doing); any visible text read word for word; \
    colors, lighting, and mood; the setting or background; and any small or \
    unusual details worth noting. Be specific and concrete.
    """

    private static func focusedPrompt(_ question: String) -> String {
        """
        Look at this image carefully. First describe what you see in detail — \
        the main subject, people, any visible text, colors, and setting. Then, \
        using only what is visible, answer this question: \(question) \
        Write several complete sentences.
        """
    }

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
        let ask = (question?.isEmpty == false) ? Self.focusedPrompt(question!) : Self.describePrompt
        let userContent = InferenceEngine.mediaMarker + ask

        do {
            let prompt = try await engine.applyChatTemplate([
                ChatMessage(role: "user", content: userContent)
            ])
            var description = ""
            for try await piece in engine.generate(
                prompt: prompt, media: [imageData], maxNewTokens: 384) {
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
