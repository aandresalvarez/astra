import Foundation

// Extracted from `TaskContextState.SourcePointer`
// (Astra/Services/Persistence/TaskContextStateManager.swift) as part of
// Track A3 (extracting the ASTRAModels SwiftPM target) - it's the only
// piece of that 2000+ line, app-side context-state persistence file that
// `Astra/Models/TaskMissionHardening.swift` needs
// (`TaskMissionCheckpointPayload.sourcePointers`). `TaskContextStateManager.swift`
// keeps a `typealias SourcePointer = TaskContextSourcePointer` so every
// existing `TaskContextState.SourcePointer` reference there is unaffected.
public struct TaskContextSourcePointer: Codable, Sendable, Equatable, Hashable {
    public var kind: String
    public var id: String?
    public var path: String?
    public var summary: String

    public init(kind: String, id: String?, path: String?, summary: String) {
        self.kind = kind
        self.id = id
        self.path = path
        self.summary = summary
    }
}
