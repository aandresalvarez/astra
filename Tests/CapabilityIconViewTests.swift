import AppKit
import Foundation
import Testing
@testable import ASTRA

@Suite("Capability Icon View")
@MainActor
struct CapabilityIconViewTests {
    @Test("asset image cache reuses decoded images for the same URL and rendering mode")
    func assetImageCacheReusesDecodedImagesForSameURLAndRenderingMode() {
        var loadCount = 0
        let cache = CapabilityIconAssetImageCache { _ in
            loadCount += 1
            return NSImage(size: NSSize(width: 12, height: 12))
        }
        let url = URL(fileURLWithPath: "/tmp/capability-icon.svg")

        let first = cache.image(contentsOf: url, renderingMode: .monochrome)
        let second = cache.image(contentsOf: url, renderingMode: .monochrome)

        #expect(loadCount == 1)
        #expect(first === second)
        #expect(first?.isTemplate == true)
    }

    @Test("asset image cache keeps monochrome and original color variants separate")
    func assetImageCacheKeepsMonochromeAndOriginalColorVariantsSeparate() {
        var loadCount = 0
        let cache = CapabilityIconAssetImageCache { _ in
            loadCount += 1
            return NSImage(size: NSSize(width: 12, height: 12))
        }
        let url = URL(fileURLWithPath: "/tmp/capability-icon.svg")

        let monochrome = cache.image(contentsOf: url, renderingMode: .monochrome)
        let originalColor = cache.image(contentsOf: url, renderingMode: .originalColor)

        #expect(loadCount == 2)
        #expect(monochrome !== originalColor)
        #expect(monochrome?.isTemplate == true)
        #expect(originalColor?.isTemplate == false)
    }
}
