import CoreGraphics
import Foundation

struct ShelfGeneratedFileDestinationMetadata: Equatable {
    let title: String
    let compactTitle: String
    let systemImage: String
}

struct ShelfDescriptor: Equatable {
    let id: ShelfID
    let title: String
    let systemImage: String
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
    let closesWhenDraggedBelowMinimum: Bool
    let generatedFileDestination: ShelfGeneratedFileDestinationMetadata?
}
