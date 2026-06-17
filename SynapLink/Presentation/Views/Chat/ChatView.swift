//
//  ChatView.swift
//  SynapLink
//
//  One conversation: streamed bubbles, stop, regenerate, and a
//  capability-driven input bar (camera/voice appear only when the loaded
//  model can see/hear).
//

import PhotosUI
import SwiftUI

struct ChatView: View {
    let chat: Chat

    @State private var session = ChatSession.shared
    @State private var draft = ""
    @State private var showAttachDialog = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingImage: Data?
    @State private var showVoiceMode = false
    @State private var showImageGen = false
    @State private var specialists = SpecialistManager.shared
    @State private var viewportHeight: CGFloat = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
            attachmentChip
            ChatInputBar(
                draft: $draft,
                supportsVision: session.canAttachMedia,
                supportsAudio: session.canSendAudio,
                isGenerating: session.isGenerating,
                canSend: session.engineState != .loading,
                hasAttachment: pendingImage != nil,
                onSend: sendDraft,
                onStop: { session.stop() },
                onCamera: { showAttachDialog = true },
                onVoice: { showVoiceMode = true },
                focused: $inputFocused)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(session.activeChat?.title ?? chat.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(modelSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAttachDialog) {
            AttachmentSheet(
                canAttachPhoto: session.canSendImages,
                onCamera: { presentAfterSheet { showCamera = true } },
                onLibrary: { presentAfterSheet { showPhotoPicker = true } },
                canCreateImage: specialists.isInstalled(.imageGen),
                onCreateImage: { presentAfterSheet { showImageGen = true } })
        }
        .sheet(isPresented: $showImageGen) {
            ImageGenSheet { prompt in session.createImage(prompt: prompt) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image, let jpeg = image.jpegData(compressionQuality: 0.85) {
                    pendingImage = Self.normalizedJPEG(from: jpeg)
                }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            Task {
                if let raw = try? await photoItem.loadTransferable(type: Data.self) {
                    pendingImage = Self.normalizedJPEG(from: raw)
                }
                self.photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showVoiceMode) {
            ImmersiveAudioView(sampleRate: session.audioCaptureSampleRate) { wav in
                showVoiceMode = false
                if let wav {
                    session.send(draft, attachments: [.init(kind: .audio, data: wav)])
                    draft = ""
                }
            }
        }
        .onAppear {
            if session.activeChat?.id != chat.id {
                session.open(chat: chat)
            }
            Task { await session.ensureEngineLoaded() }
        }
    }

    private var modelSubtitle: String {
        switch session.engineState {
        case .loading: return "loading model…"
        case .failed: return "model unavailable"
        default: return ModelDownloadManager.shared.selectedConfig.rawValue + " · on-device"
        }
    }

    /// iPhone photos arrive as HEIC, which the engine's decoder (stb_image)
    /// can't read — re-encode to JPEG and downscale: the mmproj resizes far
    /// below 1024px anyway, and smaller inputs cut A13 encode latency.
    private static func normalizedJPEG(from data: Data, maxDimension: CGFloat = 1024) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
    }

    /// Presenting a picker straight from the attachment sheet's dismissal
    /// races SwiftUI's sheet machinery; let the sheet finish closing first.
    private func presentAfterSheet(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    private func sendDraft() {
        let text = draft
        let attachments: [PendingAttachment] =
            pendingImage.map { [.init(kind: .image, data: $0)] } ?? []
        draft = ""
        pendingImage = nil
        session.send(text, attachments: attachments)
    }

    // MARK: - Attachment preview

    @ViewBuilder
    private var attachmentChip: some View {
        if let pendingImage, let uiImage = UIImage(data: pendingImage) {
            HStack {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Photo attached")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    self.pendingImage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove photo")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if session.messages.isEmpty && !session.isGenerating {
                        emptyHint
                    }
                    ForEach(session.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .contextMenu {
                                if message.id == session.messages.last?.id,
                                   message.role == .assistant, !session.isGenerating {
                                    Button("Regenerate", systemImage: "arrow.clockwise") {
                                        session.regenerate()
                                    }
                                }
                                Button("Copy", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = message.content
                                }
                            }
                    }
                    if session.isGenerating {
                        if session.isAnalyzingMedia && session.streamingText.isEmpty {
                            analyzingIndicator
                        } else {
                            MessageBubble(role: .assistant, text: session.streamingText, isStreaming: true)
                                .id("streaming")
                        }
                    }
                    if session.isCreatingImage {
                        creatingImageIndicator
                    }
                    statusBanner
                    // During a turn, reserve a near-viewport gap so the user's
                    // message can sit at the TOP with the reply streaming below
                    // it; collapses once the exchange settles.
                    Color.clear
                        .frame(height: bottomSpacer)
                        .id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onChange(of: session.messages.last?.id) {
                guard let last = session.messages.last else { return }
                // A new user message jumps to the top; a finished reply just
                // settles where it is.
                if last.role == .user {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .top)
                    }
                }
            }
            .onChange(of: session.streamingText) {
                // Follow the streaming reply: keep its latest line just above the
                // input bar. While the reply is short this clamps to the top (the
                // user message stays pinned); once it fills the screen it scrolls.
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: session.isGenerating) { _, generating in
                // Reply finished: settle the scroll on it and open the keyboard so
                // the next message can be typed straight away. The bottom spacer
                // has collapsed, so scroll explicitly to the final bubble.
                guard !generating, let last = session.messages.last else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                inputFocused = true
            }
            .onAppear {
                if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// Room below the conversation so the latest user message can scroll to the
    /// top during a turn (ChatGPT-style); near-zero at rest.
    private var bottomSpacer: CGFloat {
        guard viewportHeight > 0 else { return 8 }
        if session.isGenerating || session.isCreatingImage || session.messages.last?.role == .user {
            return viewportHeight * 0.8
        }
        return 8
    }

    /// Diffusion is slow on-device — a calmer, longer-wait affordance.
    private var creatingImageIndicator: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .symbolEffect(.variableColor.iterative)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Creating image…").font(.callout)
                    Text("On-device — this can take a while.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 48)
        }
    }

    /// Media prefill (encode) takes seconds before the first token — say so.
    private var analyzingIndicator: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .symbolEffect(.pulse)
                Text("Analyzing…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 48)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Ask anything.\nThis conversation never leaves your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBanner: some View {
        switch session.engineState {
        case .loading:
            banner(icon: nil, text: "Loading model — first time takes a few seconds…", color: .secondary)
        case .failed(let message):
            banner(icon: "exclamationmark.triangle.fill", text: message, color: .red)
        default:
            if let error = session.lastError {
                banner(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
            }
        }
    }

    private func banner(icon: String?, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .multilineTextAlignment(.leading)
        }
        .font(.footnote)
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 6)
    }
}
