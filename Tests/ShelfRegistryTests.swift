import CoreGraphics
import Testing
@testable import ASTRA

@Suite("Core shelf registry")
struct ShelfRegistryTests {
    @Test("Core registry contains existing shelf IDs")
    func coreRegistryContainsExistingShelfIDs() throws {
        let descriptors = CoreShelfRegistry.allDescriptors

        #expect(descriptors.map(\.id) == [.plan, .files, .browser, .query, .appPreview])
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)

        for id in ShelfID.allCases {
            let descriptor = try #require(CoreShelfRegistry.descriptor(for: id))
            #expect(descriptor.id == id)
        }
    }

    @Test("Core shelf descriptors preserve width constraints")
    func coreShelfDescriptorsPreserveWidthConstraints() throws {
        let expectations: [(ShelfID, String, String, CGFloat, CGFloat, CGFloat, Bool)] = [
            (.plan, "Plan", "list.bullet.rectangle", 400, 520, 1040, false),
            (.files, "Files", "doc.text", ShelfWidthMetrics.filesMinReadableWidth, 620, 980, true),
            (.browser, "Browser", "globe", ShelfWidthMetrics.browserMinWidth, 440, 1120, false),
            (.query, "Query", "cylinder.split.1x2", 460, 640, 1180, false),
            (.appPreview, "Live preview", "apps.iphone", 440, 560, 1120, false)
        ]

        for (id, title, systemImage, minWidth, idealWidth, maxWidth, closesWhenDraggedBelowMinimum) in expectations {
            let descriptor = try #require(CoreShelfRegistry.descriptor(for: id))
            #expect(descriptor.title == title)
            #expect(descriptor.systemImage == systemImage)
            #expect(descriptor.minWidth == minWidth)
            #expect(descriptor.idealWidth == idealWidth)
            #expect(descriptor.maxWidth == maxWidth)
            #expect(descriptor.closesWhenDraggedBelowMinimum == closesWhenDraggedBelowMinimum)
        }
    }

    @Test("Workspace canvas item maps to shelf ID")
    func workspaceCanvasItemMapsToShelfID() {
        #expect(WorkspaceCanvasItem.plan.shelfID == .plan)
        #expect(WorkspaceCanvasItem.markdown.shelfID == .files)
        #expect(WorkspaceCanvasItem.browser.shelfID == .browser)
        #expect(WorkspaceCanvasItem.query.shelfID == .query)
        #expect(WorkspaceCanvasItem.appPreview.shelfID == .appPreview)

        #expect(ShelfID.plan.workspaceCanvasItem == .plan)
        #expect(ShelfID.files.workspaceCanvasItem == .markdown)
        #expect(ShelfID.browser.workspaceCanvasItem == .browser)
        #expect(ShelfID.query.workspaceCanvasItem == .query)
        #expect(ShelfID.appPreview.workspaceCanvasItem == .appPreview)
    }
}
