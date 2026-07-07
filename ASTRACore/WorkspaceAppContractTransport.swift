import Foundation

// Moved here as part of Track A2.1 (finishing A2's Models cycle-break) so
// `Astra/Models/WorkspaceAppDependencyBinding.swift` can depend on it without
// pulling in the WorkspaceApps subsystem. `WorkspaceAppContractRegistry.swift`
// references this definition instead of redefining it.
public enum WorkspaceAppContractTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case native
    case http
    case cli
    case mcp
    case taskBacked
}
