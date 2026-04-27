import PhotosUI
import SwiftUI
import UIKit

enum QuickThreadComposerMode: String, Identifiable {
    case camera
    case prompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .prompt: return "New Chat"
        }
    }
}

struct QuickThreadPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: QuickThreadComposerMode
    let onSend: (String, UIImage?) async throws -> Void

    @State private var prompt = ""
    @State private var image: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isSending = false
    @State private var errorMessage: String?

    private var canSend: Bool {
        !isSending && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .camera {
                    cameraSurface
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(mode == .camera ? "Add context" : "Prompt")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField(mode == .camera ? "What should the agent do with this?" : "Ask anything...", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(3...8)
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)
            }
            .scrollDismissesKeyboard(.interactively)
            .padding(18)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        AppHaptics.light()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        send()
                    } label: {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Send")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .task(id: selectedPhoto) {
                guard let selectedPhoto else { return }
                if let data = try? await selectedPhoto.loadTransferable(type: Data.self),
                   let photo = UIImage(data: data) {
                    image = photo
                    AppHaptics.light()
                }
            }
            .onAppear {
                guard mode == .camera, image == nil else { return }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(image: $image)
                    .ignoresSafeArea()
            }
        }
    }

    private var cameraSurface: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
            .clipped()

            HStack(spacing: 10) {
                Button {
                    AppHaptics.light()
                    showCamera = true
                } label: {
                    Label(image == nil ? "Take Photo" : "Retake", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func send() {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        AppHaptics.medium()

        Task {
            do {
                try await onSend(prompt.trimmingCharacters(in: .whitespacesAndNewlines), image)
                AppHaptics.light()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                AppHaptics.medium()
            }
            isSending = false
        }
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var image: UIImage?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(image: $image, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        @Binding private var image: UIImage?
        private let dismiss: DismissAction

        init(image: Binding<UIImage?>, dismiss: DismissAction) {
            _image = image
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            image = info[.originalImage] as? UIImage
            AppHaptics.light()
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
