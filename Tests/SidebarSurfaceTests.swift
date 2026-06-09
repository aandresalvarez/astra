import SwiftUI
import Testing
@testable import ASTRA

@MainActor
@Suite("SidebarSurface")
struct SidebarSurfaceTests {

    @Test("Sidebar surface supports trailing content builder initialization")
    func supportsTrailingContentBuilderInitialization() {
        let surface = SidebarSurface(style: .floating, width: 333) {
            Text("Sidebar")
        }

        #expect(surface.style == .floating)
        #expect(surface.width == 333)
    }
}
