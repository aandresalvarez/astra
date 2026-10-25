import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The plugin catalog a routine or template editor offers skills from.
///
/// Loaded once, off the main thread (as the composer's catalog is), and kept
/// in the editor's state, so rendering resolves `routineSkills` against it
/// instead of scanning the library on every `body` pass. The scheduler, which
/// isn't a view, keeps resolving against the library when a routine fires.
struct RoutineSkillCatalog: Sendable {
    /// Until the library is read: the built-in plugins, which the definition
    /// overload merges in anyway.
    static let builtIns = RoutineSkillCatalog(packages: [], approvalRecords: [], packPolicy: .empty)

    var packages: [PluginPackage]
    var approvalRecords: [CapabilityApprovalRecord]
    var packPolicy: PackResolvedPolicy

    /// `selection` less the skills durable state no longer offers: the
    /// editor's catalog was loaded once, and a plugin removed or updated
    /// away from a skill while the editor stayed open would otherwise be
    /// saved as a dangling routine reference. Resolved against the library
    /// (the scheduler's rule), once, at commit.
    @MainActor
    static func validatedSelection(_ selection: [String], in workspace: Workspace, globalSkills: [Skill]) -> [String] {
        let offered = Set(WorkspaceCapabilities.routineSkills(in: workspace, globalSkills: globalSkills).map { $0.id.uuidString })
        return selection.filter { offered.contains($0) }
    }

    static func load(enabledPackIDs: [String]) async -> RoutineSkillCatalog {
        await Task.detached(priority: .userInitiated) {
            RoutineSkillCatalog(
                packages: CapabilityLibrary().installedPackages(),
                approvalRecords: CapabilityApprovalStore().records(),
                packPolicy: PackWorkspacePolicyProvider.resolvedPolicy(enabledPackIDs: enabledPackIDs)
            )
        }.value
    }
}
