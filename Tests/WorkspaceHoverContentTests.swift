import AppKit
import SwiftUI
import Testing
@testable import ASTRA

@Suite("Workspace hover content lifecycle")
@MainActor
struct WorkspaceHoverContentTests {
    @Test("Repeated sidebar updates do not construct closed hover cards")
    func closedCardsAreLazy() {
        let content = WorkspaceHoverContent()
        var builds = 0
        for _ in 0..<100 {
            content.update {
                builds += 1
                return AnyView(Text("Workspace options"))
            }
        }
        #expect(builds == 0)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        content.attach(to: host)
        #expect(builds == 1)
    }

    @Test("Visible cards refresh and reopening uses the latest builder")
    func visibleUpdatesAndReopening() {
        let content = WorkspaceHoverContent()
        var renderedVersions: [Int] = []
        func update(_ version: Int) {
            content.update {
                renderedVersions.append(version)
                return AnyView(Text("Version \(version)"))
            }
        }
        update(1)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        content.attach(to: host)
        update(2)
        #expect(renderedVersions == [1, 2])
        content.detach()
        update(3)
        update(4)
        #expect(renderedVersions == [1, 2])
        content.attach(to: host)
        #expect(renderedVersions == [1, 2, 4])
    }

    @Test("The content builder does not retain a dismissed host")
    func hostOwnership() {
        let content = WorkspaceHoverContent()
        weak var releasedHost: NSHostingView<AnyView>?
        autoreleasepool {
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            releasedHost = host
            content.attach(to: host)
        }
        #expect(releasedHost == nil)
        content.update { AnyView(Text("Still closed")) }
    }
}
