//
//  HomeView.swift
//  SynapLink
//
//  Landing tab: a greeting, a prompt, and a card grid of the primary actions
//  (Chat, Create Image) — the screenshot-style home. The toolbar keeps the
//  profile icon (left) and history (right). Image creation is a first-class
//  card so "make me an image" goes to the generator, not the text model.
//

import SwiftUI

struct HomeView: View {
    @State private var downloadManager = ModelDownloadManager.shared
    @State private var specialists = SpecialistManager.shared
    @State private var router = AppRouter.shared
    @State private var topicSuggester = TopicSuggester.shared
    @State private var showModelLibrary = false
    @State private var showImageGen = false
    @State private var showHistory = false

    // Phase 4 will pull the real profile name; placeholder for now.
    private let userName = "User"

    private var hasModel: Bool { downloadManager.isAvailable }
    private var hasImageGen: Bool { specialists.isInstalled(.imageGen) }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    greeting
                    Text("How may I help you?")
                        .font(.title.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    cards
                    if hasModel, topicSuggester.isLoading || !topicSuggester.topics.isEmpty {
                        topicsSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .synapTabBarInset()
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        router.tab = .settings  // profile lives in Settings (photo lands in Phase 4)
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.title2)
                    }
                    .accessibilityLabel("Profile")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                    .accessibilityLabel("Chat history")
                }
            }
            .navigationDestination(isPresented: $showHistory) {
                ChatListView()
            }
            .sheet(isPresented: $showModelLibrary) {
                NavigationStack {
                    ModelLibraryView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showModelLibrary = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showImageGen) {
                ImageGenSheet { prompt in startImageGeneration(prompt) }
            }
            .onAppear {
                downloadManager.refreshStates()
                specialists.refreshStates()
                topicSuggester.loadIfNeeded()
            }
        }
    }

    // MARK: - Greeting

    private var greeting: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Hello,")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(userName)
                .font(.title2.weight(.bold))
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var cards: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            if hasModel {
                HomeCard(title: "Chat", icon: "bubble.right.fill", tint: .red) {
                    router.openNewChat()
                }
                if hasImageGen {
                    HomeCard(title: "Create an image", icon: "photo.fill", tint: .teal) {
                        showImageGen = true
                    }
                }
            } else {
                HomeCard(title: "Set up a model", icon: "arrow.down.circle.fill", tint: .blue) {
                    showModelLibrary = true
                }
            }
        }
    }

    // MARK: - Popular topics

    private static let topicIcons = [
        "sparkles", "lightbulb.fill", "globe.americas.fill",
        "atom", "book.fill", "brain.head.profile"
    ]

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Popular topics")
                    .font(.headline)
                Spacer()
                Button {
                    topicSuggester.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(topicSuggester.isLoading)
                .accessibilityLabel("Shuffle topics")
            }

            if topicSuggester.topics.isEmpty {
                ForEach(0..<4, id: \.self) { _ in TopicSkeletonRow() }
            } else {
                ForEach(Array(topicSuggester.topics.enumerated()), id: \.element) { index, topic in
                    TopicRow(topic: topic, icon: Self.topicIcons[index % Self.topicIcons.count]) {
                        openTopic(topic)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func startImageGeneration(_ prompt: String) {
        guard let chat = ChatSession.shared.startNewChat() else { return }
        ChatSession.shared.createImage(prompt: prompt)
        router.openChat(chat)
    }

    /// Open a fresh chat seeded with a request to explore the tapped topic.
    private func openTopic(_ topic: String) {
        guard let chat = ChatSession.shared.startNewChat() else { return }
        router.openChat(chat)
        ChatSession.shared.send("Tell me about \(topic).")
    }
}

/// A tappable suggested-topic row: tinted icon, the topic, and a launch arrow.
private struct TopicRow: View {
    let topic: String
    let icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Text(topic)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Skeleton placeholder shown (with shimmer) while topics generate.
private struct TopicSkeletonRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(height: 52)
            .overlay(alignment: .leading) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 30, height: 30)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 12)
                    Spacer(minLength: 60)
                }
                .padding(.horizontal, 14)
                .shimmering()
            }
    }
}

/// Screenshot-style action tile: a colored circular icon, a title, and a
/// trailing arrow, on an elevated rounded card.
private struct HomeCard: View {
    let title: String
    let icon: String
    let tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint.gradient, in: Circle())

                Spacer(minLength: 28)

                HStack(alignment: .bottom) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(height: 160, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HomeView()
}
