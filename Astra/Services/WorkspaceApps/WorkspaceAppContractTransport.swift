import Foundation

// Defined in F1 because `WorkspaceAppDependencyBinding` (a model) depends on it.
// When F3 re-lands `WorkspaceAppContractRegistry.swift`, that file must NOT
// redefine this enum — it references the definition here instead.
enum WorkspaceAppContractTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case native
    case http
    case cli
    case mcp
    case taskBacked
}
