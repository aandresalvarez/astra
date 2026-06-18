import AppKit
import SwiftUI

struct CapabilityIconView: View {
    let presentation: CapabilityIconPresentation
    let size: CGFloat
    let color: Color
    var weight: Font.Weight = .medium

    var body: some View {
        switch presentation.kind {
        case .systemSymbol(let name):
            Image(systemName: name)
                .font(Stanford.ui(size, weight: weight))
                .foregroundStyle(color)
        case .brand(let brand):
            // All brand artwork lives in BrandMark — one catalog of vector path
            // data shared with the rail and manager surfaces — instead of
            // parallel hand-coded shapes per surface.
            BrandMarkShape(mark: brand.brandMark)
                .fill(color)
                .frame(width: size, height: size)
        case .asset(let url):
            CapabilityAssetIconView(
                url: url,
                fallbackSystemName: presentation.fallbackSystemName,
                monochromePreferred: presentation.monochromePreferred,
                size: size,
                color: color,
                weight: weight
            )
        }
    }
}

enum CapabilityIconAssetRenderingMode: Hashable {
    case monochrome
    case originalColor
}

final class CapabilityIconAssetImageCache {
    static let shared = CapabilityIconAssetImageCache()

    private struct Key: Hashable {
        var url: URL
        var renderingMode: CapabilityIconAssetRenderingMode
    }

    private var images: [Key: NSImage] = [:]
    private let loader: (URL) -> NSImage?

    init(loader: @escaping (URL) -> NSImage? = { NSImage(contentsOf: $0) }) {
        self.loader = loader
    }

    func image(
        contentsOf url: URL,
        renderingMode: CapabilityIconAssetRenderingMode
    ) -> NSImage? {
        let key = Key(url: url.standardizedFileURL, renderingMode: renderingMode)
        if let image = images[key] {
            return image
        }
        guard let loaded = loader(url) else { return nil }
        let image = (loaded.copy() as? NSImage) ?? loaded
        image.isTemplate = renderingMode == .monochrome
        images[key] = image
        return image
    }
}

private struct CapabilityAssetIconView: View {
    let url: URL
    let fallbackSystemName: String
    let monochromePreferred: Bool
    let size: CGFloat
    let color: Color
    let weight: Font.Weight

    @State private var image: NSImage?

    private var renderingMode: CapabilityIconAssetRenderingMode {
        monochromePreferred ? .monochrome : .originalColor
    }

    var body: some View {
        Group {
            if let image {
                assetImage(image)
            } else {
                fallbackIcon
            }
        }
        .onAppear(perform: loadImage)
        .onChange(of: url) { loadImage() }
        .onChange(of: monochromePreferred) { loadImage() }
    }

    @ViewBuilder
    private func assetImage(_ image: NSImage) -> some View {
        if monochromePreferred {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .frame(width: size, height: size)
        } else {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemName)
            .font(Stanford.ui(size, weight: weight))
            .foregroundStyle(color)
    }

    private func loadImage() {
        image = CapabilityIconAssetImageCache.shared.image(
            contentsOf: url,
            renderingMode: renderingMode
        )
    }
}

extension CapabilityBrandIcon {
    /// The shared artwork for this presentation-layer brand. The mapping lives
    /// with rendering (not in the Services presentation file) so the Services
    /// layer never references view-layer types.
    var brandMark: BrandMark {
        switch self {
        case .github: .github
        case .jira: .jira
        case .googleDrive: .googleDrive
        case .googleCloud: .googleCloud
        case .microsoft365: .microsoft365
        }
    }
}
