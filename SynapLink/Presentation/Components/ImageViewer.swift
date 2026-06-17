//
//  ImageViewer.swift
//  SynapLink
//
//  Full-screen preview for a tapped chat image, with a download/share action
//  (system share sheet → Save Image / Save to Files / AirDrop). Saving to the
//  photo library uses NSPhotoLibraryAddUsageDescription.
//

import SwiftUI

struct ImageViewer: View {
    let image: UIImage

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding()
        }
        .overlay(alignment: .top) {
            HStack {
                button("xmark", "Close") { dismiss() }
                Spacer()
                button("square.and.arrow.down", "Save or share") { showShare = true }
            }
            .padding(.horizontal, 16)
            .foregroundStyle(.white)
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [image])
        }
    }

    private func button(_ systemName: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }
}

/// Thin wrapper over UIActivityViewController for SwiftUI presentation.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
