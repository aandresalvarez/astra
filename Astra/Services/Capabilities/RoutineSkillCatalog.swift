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
