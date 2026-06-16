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
    @State private var showModelLibrary = false
    @State private var showImageGen = false
    @State private var showHistory = false

    // Phase 4 will pull the real profile name; placeholder for now.
    private let userName = "User"

    private var hasModel: Bool { downloadManager.isAvailable }
    private var hasImageGen: Bool { specialists.isInstalled(.imageGen) }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
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

    // MARK: - Actions

    private func startImageGeneration(_ prompt: String) {
        guard let chat = ChatSession.shared.startNewChat() else { return }
        ChatSession.shared.createImage(prompt: prompt)
        router.openChat(chat)
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
