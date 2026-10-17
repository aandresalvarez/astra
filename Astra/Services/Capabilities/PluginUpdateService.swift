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
/// and is idempotent:
///
/// - A component the new definition `replaces` takes over the old one's
///   settings, account bindings, override and secret settings (a value the
///   new component already has wins), and the templates and schedules that
///   named its skill.
/// - A component the activation knew that is gone, and not taken over, is
///   released: settings and bindings deleted (the accounts stay), its secret
///   namespace journaled for cleanup, its skill dropped from templates and
///   schedules. A setting a kept component no longer declares is released
///   too, and the plugin's templates follow the definition.
/// - The activation records the new version, digest and component list.
///
/// Releasing deletes the person's state, so only their action does it
/// (`Mode.release`: an import they chose, Add, the row's Update). The
/// automatic pass (`Mode.automatic`: launch after the built-in sync, after
/// workspace recovery) only moves renamed components and records the new
/// definition when nothing else would change; otherwise the activation stays
/// on its recorded version and the row offers Update.
///
/// A rename is never inferred from a name, a kind or a service.
@MainActor
enum PluginUpdateService {
    enum UpdateError: Error, Equatable, LocalizedError {
        case refusedByWorkspace(workspace: String, reason: String)
        case secretCopyFailed(component: String, key: String)
        case storeUnreadable
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .refusedByWorkspace(let workspace, let reason):
                "\(workspace) can't take this version: \(reason)"
            case .secretCopyFailed(let component, let key):
                "Couldn't move the saved \(key) of \(component) to the new version."
            case .storeUnreadable:
                "Couldn't read the workspaces that use this plugin."
            case .saveFailed:
                "Couldn't save the update."
            }
        }
    }

    // MARK: - Component identity

    /// The components an activation's state can be keyed by, in definition order.
    nonisolated static func componentIDs(of package: PluginPackage) -> [String] {
        PluginRuntimeProjection.componentIDs(of: package)
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
        // One predecessor per component: two components folded into one
        // can't both hand over their settings, accounts and secrets.
        func single(_ olds: [String], name: String) {
            if olds.count > 1 { problems.append("\(name) replaces more than one component.") }
        }
        for skill in package.skills {
            check(CapabilityResourceOrigin.replacedComponentIDs(for: skill), kindPrefix: "skill:", name: skill.name)
            single(CapabilityResourceOrigin.replacedComponentIDs(for: skill), name: skill.name)
        }
        for connector in package.connectors {
            let service = "connector:\(CapabilityRuntimeResourceMatcher.normalizedServiceType(connector.serviceType)):"
            check(CapabilityResourceOrigin.replacedComponentIDs(for: connector), kindPrefix: service, name: connector.name)
            single(CapabilityResourceOrigin.replacedComponentIDs(for: connector), name: connector.name)
        }
        for tool in package.localTools {
            check(CapabilityResourceOrigin.replacedComponentIDs(for: tool), kindPrefix: "tool:", name: tool.name)
            single(CapabilityResourceOrigin.replacedComponentIDs(for: tool), name: tool.name)
        }
        problems += claimed.filter { $0.value > 1 }.keys.sorted().map { "\($0) is replaced by more than one component." }
        return problems
    }

    // MARK: - Preflight

    /// Workspaces with an activation of the plugin (on or off: an Update
    /// reconciles both) that would refuse `package` for a reason other than
    /// its pending review: a pack rule, a missing dependency, a conflict, an
    /// unsafe declaration.
    static func refusals(
        for package: PluginPackage,
        modelContext: ModelContext,
        approvalRecords: [CapabilityApprovalRecord] = CapabilityApprovalStore().records()
    ) -> [UpdateError] {
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()) else { return [.storeUnreadable] }
        return workspaces.compactMap { workspace -> UpdateError? in
            guard WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) != nil else { return nil }
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

    enum Mode {
        /// Moves renamed components; records the definition only when nothing
        /// would be released.
        case automatic
        /// The person's Update, import or Add: releases what the definition
        /// dropped.
        case release
    }

    /// A secret written into a namespace, and what was there before.
    struct CopiedSecret: Equatable {
        let key: String
        let skillID: UUID
        let previousValue: String?
    }

    /// A secret setting a kept component no longer declares, deleted once
    /// the reconciliation is saved.
    struct StaleSecret: Equatable {
        let key: String
        let skillID: UUID
    }

    /// What reconciling one activation did in memory, for the caller's save.
    struct Reconciliation: Equatable {
        /// Skill namespaces released, journaled with the save.
        var released: [UUID] = []
        /// Secrets copied for renames, put back if the save fails.
        var copied: [CopiedSecret] = []
        var staleSecrets: [StaleSecret] = []
        /// Whether the activation now records the definition.
        var recorded = false
        /// What an Update would release, when an automatic pass held back.
        var withheld: [String] = []
        var changed: Bool { recorded || !copied.isEmpty || !released.isEmpty }
    }

    /// True when the activation was not reconciled against this definition.
    static func needsReconcile(_ activation: PluginActivation, to package: PluginPackage) -> Bool {
        activation.recordedVersion != package.version
            || activation.recordedDigest != digest(of: package)
            || activation.knownComponentIDs != componentIDs(of: package)
    }

    /// Reconciles every activation whose definition changed and saves once,
    /// journaling released secret namespaces before the save and exporting
    /// every workspace it changed after it. Returns how many activations
    /// changed. Nothing is saved, and copied secrets are put back, when a
    /// secret can't move or the save fails.
    @discardableResult
    static func reconcileAll(
        modelContext: ModelContext,
        packages: [PluginPackage] = CapabilityRuntimeResourceMatcher.packageDefinitions(),
        mode: Mode = .automatic
    ) throws -> Int {
        let packagesByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activations = try modelContext.fetch(FetchDescriptor<PluginActivation>())
        var total = Reconciliation()
        var changedWorkspaces: [Workspace] = []
        var changed = 0
        do {
            for activation in activations where !activation.isDeleted {
                guard let workspace = activation.workspace,
                      let package = packagesByID[activation.pluginID],
                      needsReconcile(activation, to: package) || !PluginTemplateSync.isInSync(package, in: workspace)
                else { continue }
                let result = try reconcile(activation, in: workspace, to: package, mode: mode, modelContext: modelContext, copied: &total.copied)
                total.released += result.released
                total.staleSecrets += result.staleSecrets
                guard result.changed else { continue }
                changed += 1
                if !changedWorkspaces.contains(where: { $0 === workspace }) { changedWorkspaces.append(workspace) }
            }
            guard changed > 0 else { return 0 }
            let saved = PluginSecretCleanupOutbox.deleteThenClean(total.released, modelContext: modelContext) {
                (try? WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspaces: changedWorkspaces, modelContext: modelContext)) != nil
            }
            guard saved else { throw UpdateError.saveFailed }
        } catch {
            modelContext.rollback()
            undo(total.copied)
            throw error
        }
        clearStaleSecrets(total.staleSecrets)
        return changed
    }

    /// Reconciles one activation in memory. Secret settings of a renamed
    /// skill are copied to the new namespace first (recorded in `copied`, for
    /// the caller to `undo` if its save fails); a copy that fails throws
    /// before anything is released.
    static func reconcile(
        _ activation: PluginActivation,
        in workspace: Workspace,
        to package: PluginPackage,
        mode: Mode,
        modelContext: ModelContext? = nil,
        copied: inout [CopiedSecret]
    ) throws -> Reconciliation {
        var result = Reconciliation()
        let current = componentIDs(of: package)
        let currentSet = Set(current)
        let stateIDs = Set(activation.configKeys.compactMap(PluginActivation.componentID(ofSettingKey:)))
            .union(activation.secretSettingKeys.compactMap(PluginActivation.componentID(ofSettingKey:)))
            .union(activation.bindings.filter { !$0.isDeleted }.map(\.componentID))
            .union(activation.overriddenComponentIDs)
        let known = Set(activation.knownComponentIDs).union(stateIDs)
        let renames = renames(in: package)

        for (old, new) in renames.sorted(by: { $0.key < $1.key })
        where known.contains(old) && !currentSet.contains(old) {
            if old.hasPrefix("skill:"), let spec = package.skills.first(where: { CapabilityResourceOrigin.componentID(for: $0) == new }) {
                let oldID = PluginRuntimeProjection.derivedID(of: activation, componentID: old)
                let newID = PluginRuntimeProjection.derivedID(of: activation, componentID: new)
                let before = copied.count
                try copySecrets(of: spec, from: oldID, to: newID, copied: &copied)
                result.copied += copied[before...]
                retargetSkill(oldID, to: newID, in: workspace)
                result.released.append(oldID)
            }
            WorkspaceCapabilityActivation.moveComponentState(from: old, to: new, on: activation)
        }

        let dropped = known.subtracting(currentSet).subtracting(renames.keys).sorted()
        let staleKeys = staleSettings(of: activation, in: package)
        let templatesInSync = PluginTemplateSync.isInSync(package, in: workspace)
        if mode == .automatic, !dropped.isEmpty || !staleKeys.isEmpty || !templatesInSync {
            result.withheld = dropped + staleKeys.map(\.settingKey) + (templatesInSync ? [] : ["templates"])
            // The renames moved state onto components the definition still
            // declares: the history names those now.
            WorkspaceCapabilityActivation.setKnownComponents(
                activation.knownComponentIDs.map { renames[$0] ?? $0 },
                on: activation
            )
            return result
        }

        for component in dropped {
            if component.hasPrefix("skill:") {
                let oldID = PluginRuntimeProjection.derivedID(of: activation, componentID: component)
                retargetSkill(oldID, to: nil, in: workspace)
                result.released.append(oldID)
            }
            WorkspaceCapabilityActivation.dropComponentState(component, on: activation)
        }
        for stale in staleKeys {
            if activation.secretSettingKeys.contains(stale.settingKey) {
                result.staleSecrets.append(StaleSecret(
                    key: stale.key,
                    skillID: PluginRuntimeProjection.derivedID(of: activation, componentID: stale.componentID)
                ))
            }
        }
        for componentID in Set(staleKeys.map(\.componentID)) {
            let declared = Set(package.skills.first { CapabilityResourceOrigin.componentID(for: $0) == componentID }?.environmentKeys ?? [])
            WorkspaceCapabilityActivation.dropSettings(of: componentID, notIn: declared, on: activation)
        }
        if let modelContext, !templatesInSync, activation.isEnabled || !PluginTemplateSync.stamped(package.id, in: workspace).isEmpty {
            PluginTemplateSync.sync(package, in: workspace, modelContext: modelContext)
        }

        WorkspaceCapabilityActivation.setKnownComponents(current, on: activation)
        WorkspaceCapabilityActivation.recordAccepted(
            pluginID: package.id,
            version: package.version,
            digest: digest(of: package),
            in: workspace
        )
        result.recorded = true
        return result
    }

    static func digest(of package: PluginPackage) -> String {
        (try? CapabilityApprovalDigest.digest(for: package)) ?? ""
    }

    /// Puts back what `copied` overwrote, newest first.
    static func undo(_ copied: [CopiedSecret]) {
        let persistence = SkillSecretSeam.required
        for secret in copied.reversed() {
            if let previous = secret.previousValue {
                persistence.saveSecretValue(previous, key: secret.key, skillID: secret.skillID, skillName: "", allowUserInteraction: false)
            } else {
                persistence.deleteSecret(key: secret.key, skillID: secret.skillID)
            }
        }
    }

    /// Deletes secret settings a definition stopped declaring, once saved.
    static func clearStaleSecrets(_ stale: [StaleSecret]) {
        let persistence = SkillSecretSeam.required
        for secret in stale where !persistence.deleteSecret(key: secret.key, skillID: secret.skillID) {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_stale_setting", "skill_id": secret.skillID.uuidString
            ], level: .warning)
        }
    }

    // MARK: - Private

    private struct StaleSetting {
        let componentID: String
        let key: String
        var settingKey: String { PluginActivation.settingKey(componentID: componentID, key: key) }
    }

    /// Settings (and recorded secrets) of kept skills whose key the
    /// definition no longer declares.
    private static func staleSettings(of activation: PluginActivation, in package: PluginPackage) -> [StaleSetting] {
        var stale: [StaleSetting] = []
        for skill in package.skills {
            let componentID = CapabilityResourceOrigin.componentID(for: skill)
            let declared = Set(skill.environmentKeys)
            for settingKey in activation.configKeys + activation.secretSettingKeys
            where PluginActivation.componentID(ofSettingKey: settingKey) == componentID {
                let key = String(settingKey.dropFirst(componentID.count + 1))
                if !declared.contains(key), !stale.contains(where: { $0.componentID == componentID && $0.key == key }) {
                    stale.append(StaleSetting(componentID: componentID, key: key))
                }
            }
        }
        return stale
    }

    /// Copies each secret setting of a renamed skill into its successor's
    /// namespace, unless the successor already has a value of its own.
    private static func copySecrets(of spec: PluginSkill, from oldID: UUID, to newID: UUID, copied: inout [CopiedSecret]) throws {
        let persistence = SkillSecretSeam.required
        for key in spec.environmentKeys where Skill.isSecretEnvironmentKey(key) {
            guard let value = persistence.loadSecretValue(key: key, skillID: oldID, store: KeychainSecretStore()),
                  !value.isEmpty else { continue }
            let existing = persistence.loadSecretValue(key: key, skillID: newID, store: KeychainSecretStore())
            guard existing?.isEmpty ?? true else { continue }
            guard persistence.saveSecretValue(value, key: key, skillID: newID, skillName: spec.name, allowUserInteraction: false) else {
                throw UpdateError.secretCopyFailed(component: spec.name, key: key)
            }
            copied.append(CopiedSecret(key: key, skillID: newID, previousValue: existing))
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
