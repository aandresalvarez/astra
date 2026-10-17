import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Brings activations up to the plugin definition in the library (Update).
///
/// The library holds one version of a plugin, so an update is global: once a
/// new definition is in the library, every activation of it is reconciled.
/// Reconciling is a function of the activation and the new definition alone,
/// so it runs wherever a definition may have changed (an import, the
/// built-in sync at launch, Add) and is idempotent:
///
/// - A component the new definition `replaces` takes over the old one's
///   settings, account bindings, override and secret settings, and the
///   templates and schedules that named its skill.
/// - A component the activation knew that is gone, and not taken over, is
///   released: settings and bindings deleted (the accounts stay), its secret
///   namespace journaled for cleanup, its skill dropped from templates and
///   schedules.
/// - The activation records the new version, digest and component list.
///
/// A rename is never inferred from a name, a kind or a service.
@MainActor
enum PluginUpdateService {
    enum UpdateError: Error, Equatable, LocalizedError {
        case refusedByWorkspace(workspace: String, reason: String)
        case secretCopyFailed(component: String, key: String)
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .refusedByWorkspace(let workspace, let reason):
                "\(workspace) can't take this version: \(reason)"
            case .secretCopyFailed(let component, let key):
                "Couldn't move the saved \(key) of \(component) to the new version."
            case .saveFailed:
                "Couldn't save the update."
            }
        }
    }

    // MARK: - Component identity

    /// The components an activation's state can be keyed by, in definition order.
    nonisolated static func componentIDs(of package: PluginPackage) -> [String] {
        package.skills.map(CapabilityResourceOrigin.componentID(for:))
            + package.connectors.map(CapabilityResourceOrigin.componentID(for:))
            + package.localTools.map(CapabilityResourceOrigin.componentID(for:))
    }

    /// Old component ID → the new component that takes it over.
    nonisolated static func renames(in package: PluginPackage) -> [String: String] {
        var map: [String: String] = [:]
        for skill in package.skills {
            for old in CapabilityResourceOrigin.replacedComponentIDs(for: skill) {
                map[old] = CapabilityResourceOrigin.componentID(for: skill)
            }
        }
        for connector in package.connectors {
            for old in CapabilityResourceOrigin.replacedComponentIDs(for: connector) {
                map[old] = CapabilityResourceOrigin.componentID(for: connector)
            }
        }
        for tool in package.localTools {
            for old in CapabilityResourceOrigin.replacedComponentIDs(for: tool) {
                map[old] = CapabilityResourceOrigin.componentID(for: tool)
            }
        }
        return map
    }

    /// Problems with a definition's `replaces`: an entry naming another
    /// kind (or, for a connector, another service), one still declared as a
    /// component, or one claimed by two components.
    nonisolated static func replacesProblems(in package: PluginPackage) -> [String] {
        let current = Set(componentIDs(of: package))
        var claimed: [String: Int] = [:]
        var problems: [String] = []
        func check(_ olds: [String], kindPrefix: String, name: String) {
            for old in olds {
                claimed[old, default: 0] += 1
                if !old.hasPrefix(kindPrefix) {
                    problems.append("\(name) replaces \(old), which is a different kind of component.")
                }
                if current.contains(old) {
                    problems.append("\(name) replaces \(old), which the plugin still declares.")
                }
            }
        }
        for skill in package.skills {
            check(CapabilityResourceOrigin.replacedComponentIDs(for: skill), kindPrefix: "skill:", name: skill.name)
        }
        for connector in package.connectors {
            let service = "connector:\(CapabilityRuntimeResourceMatcher.normalizedServiceType(connector.serviceType)):"
            check(CapabilityResourceOrigin.replacedComponentIDs(for: connector), kindPrefix: service, name: connector.name)
        }
        for tool in package.localTools {
            check(CapabilityResourceOrigin.replacedComponentIDs(for: tool), kindPrefix: "tool:", name: tool.name)
        }
        problems += claimed.filter { $0.value > 1 }.keys.sorted().map { "\($0) is replaced by more than one component." }
        return problems
    }

    // MARK: - Preflight

    /// Workspaces that have the plugin on and would refuse `package` for a
    /// reason other than its pending review: a pack rule, a missing
    /// dependency, a conflict, an unsafe declaration.
    static func refusals(
        for package: PluginPackage,
        modelContext: ModelContext,
        approvalRecords: [CapabilityApprovalRecord] = CapabilityApprovalStore().records()
    ) -> [UpdateError] {
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        return workspaces.compactMap { workspace -> UpdateError? in
            guard WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)?.isEnabled == true else { return nil }
            let decision = CapabilityCatalogPolicy.decision(
                for: package,
                context: .currentUser(workspace: workspace, approvalRecords: approvalRecords)
            )
            let reasons = decision.blockers.filter(refusesUpdate).map(\.message)
            guard let reason = reasons.first else { return nil }
            return .refusedByWorkspace(workspace: workspace.name, reason: reason)
        }
    }

    private static func refusesUpdate(_ blocker: CapabilityCatalogBlocker) -> Bool {
        switch blocker {
        case .packPolicyRestricted, .missingDependency, .conflictsWith, .appTooOld,
             .unsafeLocalTool, .unsafeConnector, .unsafeMCPServer:
            return true
        default:
            return false
        }
    }

    // MARK: - Reconcile

    /// True when the activation was not reconciled against this definition.
    static func needsReconcile(_ activation: PluginActivation, to package: PluginPackage) -> Bool {
        activation.recordedVersion != package.version
            || activation.recordedDigest != digest(of: package)
            || activation.knownComponentIDs != componentIDs(of: package)
    }

    /// Reconciles every activation whose definition changed and saves once,
    /// journaling released secret namespaces before the save. Returns how
    /// many activations changed. Nothing is saved when a secret can't move.
    @discardableResult
    static func reconcileAll(
        modelContext: ModelContext,
        packages: [PluginPackage] = CapabilityRuntimeResourceMatcher.packageDefinitions()
    ) throws -> Int {
        let packagesByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activations = try modelContext.fetch(FetchDescriptor<PluginActivation>())
        var released: [UUID] = []
        var changed = 0
        do {
            for activation in activations where !activation.isDeleted {
                guard let workspace = activation.workspace,
                      let package = packagesByID[activation.pluginID],
                      needsReconcile(activation, to: package) else { continue }
                released += try reconcile(activation, in: workspace, to: package)
                changed += 1
            }
            guard changed > 0 else { return 0 }
            let saved = PluginSecretCleanupOutbox.deleteThenClean(released, modelContext: modelContext) {
                (try? WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: nil, modelContext: modelContext)) != nil
            }
            guard saved else { throw UpdateError.saveFailed }
        } catch {
            modelContext.rollback()
            throw error
        }
        return changed
    }

    /// Reconciles one activation in memory and returns the skill namespaces
    /// it released, for the caller to journal with its save. Secret settings
    /// of a renamed skill are copied to the new namespace first; a copy that
    /// fails throws before anything is released.
    static func reconcile(
        _ activation: PluginActivation,
        in workspace: Workspace,
        to package: PluginPackage
    ) throws -> [UUID] {
        let current = componentIDs(of: package)
        let currentSet = Set(current)
        let stateIDs = Set(activation.configKeys.compactMap { key in key.lastIndex(of: ".").map { String(key[..<$0]) } })
            .union(activation.bindings.filter { !$0.isDeleted }.map(\.componentID))
            .union(activation.overriddenComponentIDs)
        let known = Set(activation.knownComponentIDs).union(stateIDs)
        var released: [UUID] = []

        for (old, new) in renames(in: package).sorted(by: { $0.key < $1.key })
        where known.contains(old) && !currentSet.contains(old) {
            if old.hasPrefix("skill:"), let spec = package.skills.first(where: { CapabilityResourceOrigin.componentID(for: $0) == new }) {
                let oldID = PluginRuntimeProjection.derivedID(activationID: activation.id, componentID: old)
                let newID = PluginRuntimeProjection.derivedID(activationID: activation.id, componentID: new)
                try copySecrets(of: spec, from: oldID, to: newID)
                retargetSkill(oldID, to: newID, in: workspace)
                released.append(oldID)
            }
            WorkspaceCapabilityActivation.moveComponentState(from: old, to: new, on: activation)
        }

        let movedAway = Set(renames(in: package).keys)
        for dropped in known.subtracting(currentSet).subtracting(movedAway).sorted() {
            if dropped.hasPrefix("skill:") {
                let oldID = PluginRuntimeProjection.derivedID(activationID: activation.id, componentID: dropped)
                retargetSkill(oldID, to: nil, in: workspace)
                released.append(oldID)
            }
            WorkspaceCapabilityActivation.dropComponentState(dropped, on: activation)
        }

        WorkspaceCapabilityActivation.setKnownComponents(current, on: activation)
        WorkspaceCapabilityActivation.recordAccepted(
            pluginID: package.id,
            version: package.version,
            digest: digest(of: package),
            in: workspace
        )
        return released
    }

    static func digest(of package: PluginPackage) -> String {
        (try? CapabilityApprovalDigest.digest(for: package)) ?? ""
    }

    private static func copySecrets(of spec: PluginSkill, from oldID: UUID, to newID: UUID) throws {
        let persistence = SkillSecretSeam.required
        for key in spec.environmentKeys where Skill.isSecretEnvironmentKey(key) {
            guard let value = persistence.loadSecretValue(key: key, skillID: oldID, store: KeychainSecretStore()),
                  !value.isEmpty else { continue }
            guard persistence.saveSecretValue(value, key: key, skillID: newID, skillName: spec.name, allowUserInteraction: false) else {
                throw UpdateError.secretCopyFailed(component: spec.name, key: key)
            }
        }
    }

    /// Templates and schedules that named a projected skill name its
    /// successor, or drop it when it has none.
    private static func retargetSkill(_ old: UUID, to new: UUID?, in workspace: Workspace) {
        let oldID = old.uuidString
        func rewrite(_ ids: [String]) -> [String] {
            ids.compactMap { $0 == oldID ? new?.uuidString : $0 }
        }
        for template in workspace.templates where template.defaultSkillIDs.contains(oldID) {
            template.defaultSkillIDs = rewrite(template.defaultSkillIDs)
        }
        for schedule in workspace.schedules where schedule.skillIDs.contains(oldID) {
            schedule.skillIDs = rewrite(schedule.skillIDs)
        }
    }
}
