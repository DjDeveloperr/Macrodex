import SwiftUI

struct ConversationComposerAttachSheet: View {
    let onPickPhotoLibrary: () -> Void
    let onTakePhoto: () -> Void
    var onScanNutritionLabel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text("Attach")
                .macrodexFont(.headline, weight: .semibold)
                .foregroundColor(MacrodexTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onPickPhotoLibrary) {
                sheetButtonLabel("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button(action: onTakePhoto) {
                sheetButtonLabel("Take Photo", systemImage: "camera")
            }

            if let onScanNutritionLabel {
                Button(action: onScanNutritionLabel) {
                    sheetButtonLabel("Scan Nutrition Label", systemImage: "text.viewfinder")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
    }

    @ViewBuilder
    private func sheetButtonLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .macrodexFont(.body, weight: .medium)
                .foregroundColor(MacrodexTheme.textPrimary)
                .frame(width: 20)

            Text(title)
                .macrodexFont(.body, weight: .medium)
                .foregroundColor(MacrodexTheme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .modifier(GlassRoundedRectModifier(cornerRadius: 18))
    }
}
