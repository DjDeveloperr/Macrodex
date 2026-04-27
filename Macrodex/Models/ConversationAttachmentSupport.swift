import Foundation
import UIKit

struct PreparedImageAttachment {
    let data: Data
    let mimeType: String

    var userInput: AppUserInput {
        .image(url: dataURI)
    }

    var chatImage: ChatImage {
        ChatImage(data: data, mimeType: mimeType)
    }

    private var dataURI: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

enum ConversationAttachmentSupport {
    static func prepareImage(_ image: UIImage) -> PreparedImageAttachment? {
        let image = resizedImageIfNeeded(image)
        guard let encodedImage = encodedImageData(for: image) else { return nil }
        return PreparedImageAttachment(data: encodedImage.data, mimeType: encodedImage.mimeType)
    }

    static func buildTurnInputs(text: String, additionalInput: [AppUserInput]) -> [AppUserInput] {
        var inputs: [AppUserInput] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputs.append(.text(text: text, textElements: []))
        }
        inputs.append(contentsOf: additionalInput)
        return inputs
    }

    private static func encodedImageData(for image: UIImage) -> (data: Data, mimeType: String)? {
        if image.macrodexHasAlpha, let pngData = image.pngData() {
            return (pngData, "image/png")
        }
        if let jpegData = image.jpegData(compressionQuality: 0.72) {
            return (jpegData, "image/jpeg")
        }
        if let pngData = image.pngData() {
            return (pngData, "image/png")
        }
        return nil
    }

    private static func resizedImageIfNeeded(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 1600
        let size = image.size
        let largest = max(size.width, size.height)
        guard largest > maxDimension, largest > 0 else { return image }
        let scale = maxDimension / largest
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !image.macrodexHasAlpha
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private extension UIImage {
    var macrodexHasAlpha: Bool {
        guard let alphaInfo = cgImage?.alphaInfo else { return false }
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }
}
