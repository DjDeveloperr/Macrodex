import SwiftUI
import UIKit

struct BrandLogo: View {
    var size: CGFloat

    private var bundledLogo: UIImage? {
        UIImage(named: "brand_logo")
    }

    var body: some View {
        if let bundledLogo {
            Image(uiImage: bundledLogo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            HStack(spacing: size * 0.08) {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.42, weight: .semibold))
                Text("Macrodex")
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
            }
            .foregroundStyle(MacrodexTheme.accent)
        }
    }
}

#if DEBUG
#Preview("Brand Logo") {
    ZStack {
        MacrodexTheme.backgroundGradient.ignoresSafeArea()
        BrandLogo(size: 128)
    }
}
#endif
