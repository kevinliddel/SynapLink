//
//  HomeView.swift
//  SynapLink
//
//  Landing tab: first-run model setup, then the primary actions —
//  Start a chat and Create an image — plus a snapshot of what's installed.
//  Image creation is a first-class action here (not buried in chat), so
//  "make me an image" goes to the generator instead of the text model.
//

import SwiftUI

struct HomeView: View {
    @State private var downloadManager = ModelDownloadManager.shared
    @State private var specialists = SpecialistManager.shared
    @State private var router = AppRouter.shared
    @State private var showModelLibrary = false
    @State private var showImageGen = false

    private var hasModel: Bool { downloadManager.isAvailable }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    if hasModel {
                        actions
                        statusCard
                    } else {
                        setupCard
                    }
                }
                .padding()
            }
            .navigationTitle("SynapLink")
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

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor.gradient)
                .padding(.top, 12)
            Text("Your private AI")
                .font(.title.weight(.bold))
            Text("Everything runs on this device. No cloud, no account, no network.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            actionCard(title: "Start a Chat", subtitle: "Ask anything, offline",
                       icon: "bubble.left.and.bubble.right.fill", tint: .accentColor) {
                if let chat = ChatSession.shared.startNewChat() { router.openChat(chat) }
            }
            if specialists.isInstalled(.imageGen) {
                actionCard(title: "Create an Image", subtitle: "Generate art from a text prompt",
                           icon: "wand.and.stars", tint: .purple) {
                    showImageGen = true
                }
            }
        }
    }

    private func actionCard(title: String, subtitle: String, icon: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On this device").font(.subheadline.weight(.semibold))
            row(icon: "cpu", label: "Chat model", value: downloadManager.selectedConfig.rawValue)
            ForEach(SpecialistModel.allCases) { model in
                if specialists.isInstalled(model) {
                    row(icon: model.iconName, label: model.rawValue, value: "Ready")
                }
            }
            Button("Manage models") { router.tab = .settings }
                .font(.caption.weight(.medium))
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(label).font(.callout)
            Spacer()
            Text(value).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var setupCard: some View {
        VStack(spacing: 16) {
            Text("Download a model once to get started — then chat and create entirely offline.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showModelLibrary = true
            } label: {
                Label("Choose a Model", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Actions

    private func startImageGeneration(_ prompt: String) {
        guard let chat = ChatSession.shared.startNewChat() else { return }
        ChatSession.shared.createImage(prompt: prompt)
        router.openChat(chat)
    }
}

#Preview {
    HomeView()
}
