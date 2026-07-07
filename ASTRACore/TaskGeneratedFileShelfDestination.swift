import Foundation

/// Bare-cases slice of `Astra/Services/Tasks/TaskGeneratedFiles.swift`'s
/// `TaskGeneratedFileShelfDestination`, extracted for Track A4
/// (`ASTRAPersistence`): `WorkspaceFileIndexService.swift` needs this as a
/// stored-property type (surfaced back out to Views), but the case set
/// itself is pure data - only the app-side extension (`title`/
/// `compactTitle`/`systemImage`/`shelfID`/`init?(shelfID:)`) depends on the
/// app's `ShelfID`/`CoreShelfRegistry` Shelf-UI infrastructure, which stays
/// app-side.
public enum TaskGeneratedFileShelfDestination: Equatable, Hashable, Sendable {
    case browser
    case files
    case query
}
