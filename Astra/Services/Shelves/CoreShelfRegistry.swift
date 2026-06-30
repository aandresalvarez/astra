import CoreGraphics
import Foundation

enum CoreShelfRegistry {
    static let allDescriptors: [ShelfDescriptor] = [
        ShelfDescriptor(
            id: .plan,
            title: "Plan",
            systemImage: "list.bullet.rectangle",
            minWidth: 400,
            idealWidth: 520,
            maxWidth: 1040,
            closesWhenDraggedBelowMinimum: false,
            isPackAddressable: true,
            generatedFileDestination: nil
        ),
        ShelfDescriptor(
            id: .files,
            title: "Files",
            systemImage: "doc.text",
            minWidth: ShelfWidthMetrics.filesMinReadableWidth,
            idealWidth: 620,
            maxWidth: 980,
            closesWhenDraggedBelowMinimum: true,
            isPackAddressable: true,
            generatedFileDestination: ShelfGeneratedFileDestinationMetadata(
                title: "Open in Files Shelf",
                compactTitle: "Files",
                systemImage: "doc.text"
            )
        ),
        ShelfDescriptor(
            id: .browser,
            title: "Browser",
            systemImage: "globe",
            minWidth: ShelfWidthMetrics.browserMinWidth,
            idealWidth: 440,
            maxWidth: 1120,
            closesWhenDraggedBelowMinimum: false,
            isPackAddressable: true,
            generatedFileDestination: ShelfGeneratedFileDestinationMetadata(
                title: "Open in Browser Shelf",
                compactTitle: "Browser",
                systemImage: "globe"
            )
        ),
        ShelfDescriptor(
            id: .query,
            title: "Query",
            systemImage: "cylinder.split.1x2",
            minWidth: 460,
            idealWidth: 640,
            maxWidth: 1180,
            closesWhenDraggedBelowMinimum: false,
            isPackAddressable: true,
            generatedFileDestination: ShelfGeneratedFileDestinationMetadata(
                title: "Open in Query Shelf",
                compactTitle: "Query",
                systemImage: "cylinder.split.1x2"
            )
        ),
        ShelfDescriptor(
            id: .appPreview,
            title: "Live preview",
            systemImage: "apps.iphone",
            minWidth: 440,
            idealWidth: 560,
            maxWidth: 1120,
            closesWhenDraggedBelowMinimum: false,
            isPackAddressable: false,
            generatedFileDestination: nil
        )
    ]

    private static let descriptorsByID = Dictionary(uniqueKeysWithValues: allDescriptors.map { ($0.id, $0) })

    static func descriptor(for id: ShelfID) -> ShelfDescriptor? {
        descriptorsByID[id]
    }

    static func shelfID(forStableID stableID: String) -> ShelfID? {
        let trimmed = stableID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = ShelfID(rawValue: trimmed) {
            return exact
        }

        let value = trimmed.lowercased()
        if let normalized = ShelfID(rawValue: value) {
            return normalized
        }
        if value == "app-preview" || value == "apppreview" {
            return .appPreview
        }
        return nil
    }

    static func descriptor(forStableID stableID: String) -> ShelfDescriptor? {
        guard let shelfID = shelfID(forStableID: stableID) else { return nil }
        return descriptor(for: shelfID)
    }
}
