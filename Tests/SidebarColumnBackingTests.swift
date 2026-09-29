import AppKit
import Testing
@testable import ASTRA

@MainActor
@Suite("Sidebar column backing")
struct SidebarColumnBackingTests {
    /// The private column structure: wrapper > system material > SwiftUI host.
    private func makeColumn() -> (wrapper: NSView, material: NSVisualEffectView, host: NSView) {
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 400))
        let material = NSVisualEffectView(frame: wrapper.bounds)
        let host = NSView(frame: material.bounds)
        wrapper.addSubview(material)
        material.addSubview(host)
        return (wrapper, material, host)
    }

    @Test("Installs one backing between the system material and the SwiftUI host, once")
    func installsBelowTheHostOnce() {
        let column = makeColumn()

        #expect(SidebarColumnBacking.install(in: column.wrapper))
        #expect(!SidebarColumnBacking.install(in: column.wrapper))

        let layers = column.material.subviews
        #expect(layers.count == 2)
        #expect(layers.first?.identifier == SidebarColumnBacking.identifier)
        #expect(layers.last === column.host)
        #expect(layers.first?.frame == column.material.bounds)
    }

    @Test("A column without the system material is left alone")
    func ignoresAColumnWithoutMaterial() {
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 400))
        wrapper.addSubview(NSView())

        #expect(!SidebarColumnBacking.install(in: wrapper))
        #expect(wrapper.subviews.count == 1)
    }

    @Test("Paints the sidebar token per appearance and never takes a click")
    func paintsTheTokenAndIsEventTransparent() throws {
        let backing = SidebarColumnBackingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let expected: [(NSAppearance.Name, UInt)] = [
            (.aqua, Stanford.sidebarBackgroundLightHex),
            (.darkAqua, Stanford.sidebarBackgroundDarkHex)
        ]
        for (name, hex) in expected {
            backing.appearance = NSAppearance(named: name)
            backing.updateLayer()
            let cgColor = try #require(backing.layer?.backgroundColor)
            let color = try #require(NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB))
            func byte(_ value: CGFloat) -> UInt { UInt((value * 255).rounded()) }
            let painted = (byte(color.redComponent) << 16) | (byte(color.greenComponent) << 8) | byte(color.blueComponent)
            #expect(painted == hex, "backing in \(name) painted #\(String(painted, radix: 16, uppercase: true))")
            #expect(color.alphaComponent == 1)
        }
        #expect(backing.hitTest(NSPoint(x: 50, y: 50)) == nil)
    }
}
