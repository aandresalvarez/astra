import AppKit
import Testing
@testable import ASTRA

@Suite("App icon assets")
struct AppIconAssetTests {
    @Test(
        "Dock icons reserve the macOS optical margin",
        arguments: ["AppIcon", "AppIconDev"]
    )
    func dockIconReservesOpticalMargin(resourceName: String) throws {
        let bundle = AstraResourceBundle.current
        let iconURL = try #require(bundle.url(forResource: resourceName, withExtension: "icns"))
        let icon = try #require(NSImage(contentsOf: iconURL))
        let bitmap = try #require(
            icon.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .max { lhs, rhs in lhs.pixelsWide < rhs.pixelsWide }
        )

        let horizontalFill = try visibleFillRatio(
            length: bitmap.pixelsWide,
            alphaAt: { x in bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.alphaComponent }
        )
        let verticalFill = try visibleFillRatio(
            length: bitmap.pixelsHigh,
            alphaAt: { y in bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.alphaComponent }
        )

        // macOS Dock icons use transparent space around the optical tile. Keep
        // ASTRA close to the 84-88% fill used by nearby system and third-party
        // icons so its rounded square does not render larger than its peers.
        #expect((0.84...0.90).contains(horizontalFill))
        #expect((0.84...0.90).contains(verticalFill))
    }

    private func visibleFillRatio(
        length: Int,
        alphaAt: (Int) -> CGFloat?
    ) throws -> Double {
        let visible = (0..<length).filter { (alphaAt($0) ?? 0) > 0.001 }
        let first = try #require(visible.first)
        let last = try #require(visible.last)
        return Double(last - first + 1) / Double(length)
    }
}
