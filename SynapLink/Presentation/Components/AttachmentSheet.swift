//
//  AttachmentSheet.swift
//  SynapLink
//
//  Bottom-sheet attachment picker (Messenger / ChatGPT style): a compact
//  card of large tappable rows instead of a system action sheet.
//

import SwiftUI
import UIKit

struct AttachmentSheet: View {
    var canAttachPhoto: Bool = true
    var onCamera: () -> Void
    var onLibrary: () -> Void
    var canCreateImage: Bool = false
    var onCreateImage: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private var cameraAvailable: Bool {
        canAttachPhoto && UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var detentHeight: CGFloat {
        var rows = 0
        if canAttachPhoto { rows += 1 }    // library
        if cameraAvailable { rows += 1 }
        if canCreateImage { rows += 1 }
        return CGFloat(max(1, rows)) * 68 + 70
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            Text("Add to the conversation")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                if cameraAvailable {
                    row(title: "Take Photo", subtitle: "Use the camera",
                        icon: "camera.fill", tint: .blue) {
                        dismiss(); onCamera()
                    }
                    Divider().padding(.leading, 72)
                }
                if canAttachPhoto {
                    row(title: "Photo Library", subtitle: "Choose an existing photo",
                        icon: "photo.on.rectangle.angled", tint: .green) {
                        dismiss(); onLibrary()
                    }
                }
                if canCreateImage {
                    if canAttachPhoto { Divider().padding(.leading, 72) }
                    row(title: "Create with AI", subtitle: "Generate an image from text",
                        icon: "wand.and.stars", tint: .purple) {
                        dismiss(); onCreateImage()
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)

            Spacer(minLength: 12)
        }
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.hidden)
    }

    private func row(title: String, subtitle: String, icon: String, tint: Color,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        AttachmentSheet(onCamera: {}, onLibrary: {})
    }
}
