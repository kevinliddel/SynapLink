//
//  TopicSuggester.swift
//  SynapLink
//
//  Drives the "Popular topics" strip on Home. Topics are model-generated once
//  per session (cached so tab switches don't regenerate) with an explicit
//  shuffle. While a batch is generating, the view shows skeleton shimmer rows.
//

import Foundation
import Observation

@MainActor
@Observable
final class TopicSuggester {

    static let shared = TopicSuggester()

    private(set) var topics: [String] = []
    private(set) var isLoading = false

    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {}

    /// Generate once per session — no-op if already loaded, in flight, or no
    /// chat model is installed yet.
    func loadIfNeeded() {
        guard topics.isEmpty, !isLoading, task == nil,
              ModelDownloadManager.shared.isAvailable else { return }
        refresh()
    }

    /// Force a fresh batch (the shuffle button). Clears the current set so the
    /// skeleton shows again while the model thinks.
    func refresh() {
        guard ModelDownloadManager.shared.isAvailable else { return }
        task?.cancel()
        topics = []
        isLoading = true
        task = Task { [weak self] in
            let result = await ChatSession.shared.suggestTopics()
            guard let self, !Task.isCancelled else { return }
            self.topics = result
            self.isLoading = false
            self.task = nil
        }
    }
}
