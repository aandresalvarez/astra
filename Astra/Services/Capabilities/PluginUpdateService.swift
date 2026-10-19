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
/// on its recorded version, marked as awaiting Update (`awaitingUpdate`, so
/// its plugin doesn't run even when only the digest changed), and the row
/// offers Update.
///
/// A rename is never inferred from a name, a kind or a service.
@MainActor
enum PluginUpdateService {
    enum UpdateError: Error, Equatable, LocalizedError {
        case refusedByWorkspace(workspace: String, reason: String)
        case secretCopyFailed(component: String, key: String)
        case ambiguousRename(component: String)
        /// A secret setting the definition declares again still has an old
        /// value waiting to be cleared from the Keychain.
        case secretCleanupPending(key: String)
        case storeUnreadable
        /// The plugin's installed definition couldn't be read back.
        case definitionUnreadable(plugin: String)
        case saveFailed
        /// The update failed and a secret it had copied couldn't be put back.
        case credentialRestoreFailed(keys: [String])

        var errorDescription: String? {
            switch self {
            case .refusedByWorkspace(let workspace, let reason):
                "\(workspace) can't take this version: \(reason)"
            case .secretCopyFailed(let component, let key):
                "Couldn't move the saved \(key) of \(component) to the new version."
            case .ambiguousRename(let component):
                "\(component) takes over more than one component this workspace still has settings for, so the update can't tell whose to keep."
            case .secretCleanupPending(let key):
                "The earlier saved \(key) couldn't be cleared from the Keychain yet, so this version can't use it. Try again."
            case .storeUnreadable:
                "Couldn't read the workspaces that use this plugin."
            case .definitionUnreadable(let plugin):
                "Couldn't read the installed \(plugin), so nothing was updated. Install it again and retry."
            case .saveFailed:
                "Couldn't save the update."
            case .credentialRestoreFailed(let keys):
                "Couldn't save the update, and the saved \(keys.joined(separator: ", ")) it had moved couldn't be put back. Enter \(keys.count == 1 ? "it" : "them") again in the plugin's settings."
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
        // A component may list several historical identities (A, then B,
        // for an update straight from A to C). Only when an activation still
        // holds more than one of them is the rename ambiguous, and that is
        // refused when reconciling (`UpdateError.ambiguousRename`).
        for skill in package.skills {
            check(CapabilityResourceOrigin.replacedComponentIDs(for: skill), kindPrefix: "skill:", name: skill.name)
        }
        for connector in package.connectors {
            let service = CapabilityResourceOrigin.connectorPrefix(serviceType: connector.serviceType)
            check(CapabilityResourceOrigin.replacedComponentIDs(for: connector), kindPrefix: service, name: connector.name)
        }
        for tool in package.localTools {
            check(CapabilityResourceOrigin.replacedComponentIDs(for: tool), kindPrefix: "tool:", name: tool.name)
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

    /// A secret written into a namespace, and what was there before: a
    /// renamed skill's, copied to its successor, or an account setting
    /// moved into the Keychain (`account`; `skillID` is then the account's).
    struct CopiedSecret: Equatable {
        let key: String
        let skillID: UUID
        let previousValue: String?
        var account: ConnectorSettingSecretWrite?

        init(key: String, skillID: UUID, previousValue: String?) {
            self.key = key
            self.skillID = skillID
            self.previousValue = previousValue
        }

        init(_ write: ConnectorSettingSecretWrite) {
            self.init(key: write.key, skillID: write.facts.id, previousValue: write.previousValue)
            account = write
        }
    }

    /// A secret setting a kept component no longer declares: recorded in
    /// `PluginSecretCleanupOutbox` with the save and deleted after it.
    struct StaleSecret: Hashable {
        let key: String
        let skillID: UUID
    }

    /// What reconciling one activation did in memory, for the caller's save.
    struct Reconciliation: Equatable {
        /// Skill namespaces released, journaled with the save.
        var released: [UUID] = []
        /// Secrets copied for renames and account settings moved into the
        /// Keychain, put back if the save fails.
        var copied: [CopiedSecret] = []
        var staleSecrets: [StaleSecret] = []
        /// Whether the activation now records the definition.
        var recorded = false
        /// What an Update would release, when an automatic pass held back.
        var withheld: [String] = []
        /// Whether a rename moved state (a connector's binding, a tool's
        /// override) without copying a secret.
        var moved = false
        /// Whether a held-back pass newly marked the activation as awaiting
        /// Update.
        var marked = false
        /// Account rows the sync changed: every mirror carrying one is
        /// rewritten, not only the activation's workspace's.
        var changedAccountIDs: Set<UUID> = []
        var changed: Bool { recorded || moved || marked || !copied.isEmpty || !released.isEmpty }
    }

    /// True when the activation was not reconciled against this definition,
    /// or a pass held it back from it. A digest recorded before content
    /// digests (`PluginDefinitionDigest`) can't be judged: only the version
    /// and components are compared until one is recorded.
    static func needsReconcile(_ activation: PluginActivation, to package: PluginPackage) -> Bool {
        activation.awaitingUpdate
            || activation.recordedVersion != package.version
            || PluginDefinitionDigest.matches(activation.recordedDigest, package) == false
            || activation.knownComponentIDs != componentIDs(of: package)
    }

    /// Reconciles every activation whose definition changed and saves once,
    /// journaling released secret namespaces before the save, and rewriting
    /// every mirror it changed (the reconciled workspaces', and each one
    /// carrying a changed account) before they are cleaned. A definition
    /// awaiting its review (`approvalRecords`) changes nothing but marking
    /// the activation awaiting Update, until an approval covers its digest.
    /// Returns how many activations changed. Nothing is saved, and copied secrets
    /// are put back, when a secret can't move or the save fails.
    @discardableResult
    static func reconcileAll(
        modelContext: ModelContext,
        packages: [PluginPackage] = CapabilityRuntimeResourceMatcher.packageDefinitions(),
        mode: Mode = .automatic,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        connectorStore: SecretStore? = nil,
        approvalRecords: [CapabilityApprovalRecord]? = nil,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws -> Int {
        let approvalRecords = approvalRecords ?? CapabilityApprovalStore().records()
        let packagesByID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activations = try modelContext.fetch(FetchDescriptor<PluginActivation>())
        var total = Reconciliation()
        var changedWorkspaces: [Workspace] = []
        var changed = 0
        // rollback() doesn't restore array-backed fields (activation
        // records, template and schedule skill IDs, account keys), so a
        // failed update puts them back itself.
        let restore = captureState(of: activations.compactMap(\.workspace).filter { workspace in
            WorkspaceCapabilityActivation.activations(of: workspace).contains { packagesByID[$0.pluginID] != nil }
        })
        do {
            for activation in activations where !activation.isDeleted {
                guard let workspace = activation.workspace,
                      let package = packagesByID[activation.pluginID],
                      needsReconcile(activation, to: package) || !PluginTemplateSync.isInSync(package, in: workspace)
                else { continue }
                let result = try reconcile(
                    activation, in: workspace, to: package, mode: mode, modelContext: modelContext, secrets: secrets,
                    connectorStore: connectorStore,
                    awaitsReview: awaitsReview(package, in: workspace, approvalRecords: approvalRecords),
                    copied: &total.copied
                )
                total.released += result.released
                total.staleSecrets += result.staleSecrets
                total.changedAccountIDs.formUnion(result.changedAccountIDs)
                guard result.changed else { continue }
                changed += 1
                if !changedWorkspaces.contains(where: { $0 === workspace }) { changedWorkspaces.append(workspace) }
            }
            guard changed > 0 else { return 0 }
            let mirrored = changedWorkspaces + WorkspaceConfigManager.workspacesMirroring(
                accountIDs: total.changedAccountIDs, among: try modelContext.fetch(FetchDescriptor<Workspace>()), modelContext: modelContext
            )
            let rewrite = rewriteMirror ?? { WorkspaceConfigManager.exportMirrorNow(workspace: $0, modelContext: modelContext) }
            let saved = PluginSecretCleanupOutbox.deleteThenClean(
                total.released, keys: total.staleSecrets, modelContext: modelContext, secrets: secrets,
                save: { WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: modelContext) },
                beforeSettling: {
                    var seen = Set<UUID>()
                    return mirrored.filter { seen.insert($0.id).inserted }.reduce(true) { rewrite($1) && $0 }
                }
            )
            guard saved else { throw UpdateError.saveFailed }
        } catch {
            modelContext.rollback()
            restore()
            // A copy the Keychain can't take back is reported ahead of the
            // failure: the successor would keep a value Update reads as its own.
            let unrestored = undo(total.copied, secrets: secrets, connectorStore: connectorStore)
            if !unrestored.isEmpty { throw UpdateError.credentialRestoreFailed(keys: unrestored) }
            throw error
        }
        return changed
    }

    /// What reconciling may change in `workspaces`, as a closure that puts
    /// it back.
    static func captureState(of workspaces: [Workspace]) -> () -> Void {
        var restorers: [() -> Void] = []
        var seen = Set<UUID>()
        for workspace in workspaces where seen.insert(workspace.id).inserted {
            let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
            restorers.append { WorkspaceCapabilityActivation.restore(snapshot, to: workspace) }
            for template in workspace.templates where !template.isDeleted {
                let saved = TemplateState(template)
                restorers.append { saved.restore(onto: template) }
            }
            for schedule in workspace.schedules where !schedule.isDeleted {
                let skillIDs = schedule.skillIDs
                restorers.append { if schedule.skillIDs != skillIDs { schedule.skillIDs = skillIDs } }
            }
            for account in WorkspaceCapabilityActivation.activations(of: workspace)
                .flatMap(\.bindings).compactMap(\.account) where !account.isDeleted {
                let saved = (account.credentialKeys, account.credentialValues, account.configKeys, account.configValues,
                             account.connectorDescription, account.icon, account.notes, account.originPackageVersion,
                             account.originComponentID)
                restorers.append {
                    account.credentialKeys = saved.0
                    account.credentialValues = saved.1
                    account.configKeys = saved.2
                    account.configValues = saved.3
                    account.connectorDescription = saved.4
                    account.icon = saved.5
                    account.notes = saved.6
                    account.originPackageVersion = saved.7
                    account.originComponentID = saved.8
                }
            }
        }
        return { restorers.forEach { $0() } }
    }

    /// A template's fields Update may write.
    private struct TemplateState {
        let defaultSkillIDs: [String]
        let name, icon, templateDescription, mainGoal, beforeGoal, afterGoal, variablesJSON: String
        let mainBudget, beforeBudget, afterBudget: Int
        let passContextToMain, passContextToAfter: Bool
        let originPackageID, originPackageVersion, originComponentID, originComponentKind, originSourceKind: String?

        init(_ template: TaskTemplate) {
            defaultSkillIDs = template.defaultSkillIDs
            name = template.name
            icon = template.icon
            templateDescription = template.templateDescription
            mainGoal = template.mainGoal
            beforeGoal = template.beforeGoal
            afterGoal = template.afterGoal
            variablesJSON = template.variablesJSON
            mainBudget = template.mainBudget
            beforeBudget = template.beforeBudget
            afterBudget = template.afterBudget
            passContextToMain = template.passContextToMain
            passContextToAfter = template.passContextToAfter
            originPackageID = template.originPackageID
            originPackageVersion = template.originPackageVersion
            originComponentID = template.originComponentID
            originComponentKind = template.originComponentKind
            originSourceKind = template.originSourceKind
        }

        func restore(onto template: TaskTemplate) {
            template.defaultSkillIDs = defaultSkillIDs
            template.name = name
            template.icon = icon
            template.templateDescription = templateDescription
            template.mainGoal = mainGoal
            template.beforeGoal = beforeGoal
            template.afterGoal = afterGoal
            template.variablesJSON = variablesJSON
            template.mainBudget = mainBudget
            template.beforeBudget = beforeBudget
            template.afterBudget = afterBudget
            template.passContextToMain = passContextToMain
            template.passContextToAfter = passContextToAfter
            template.originPackageID = originPackageID
            template.originPackageVersion = originPackageVersion
            template.originComponentID = originComponentID
            template.originComponentKind = originComponentKind
            template.originSourceKind = originSourceKind
        }
    }

    /// Reconciles one activation in memory. Secret settings of a renamed
    /// skill are copied to the new namespace first (recorded in `copied`, for
    /// the caller to `undo` if its save fails); a copy that fails throws
    /// before anything is released. A definition awaiting its review
    /// (`awaitsReview`) moves nothing: no rename, account sync, release or
    /// template, in either mode. Its manifest's `replaces` is not yet the
    /// person's word, and a draft rejected later couldn't move state back.
    static func reconcile(
        _ activation: PluginActivation,
        in workspace: Workspace,
        to package: PluginPackage,
        mode: Mode,
        modelContext: ModelContext? = nil,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        connectorStore: SecretStore? = nil,
        awaitsReview: Bool = false,
        copied: inout [CopiedSecret]
    ) throws -> Reconciliation {
        let persistence = secrets ?? SkillSecretSeam.required
        var result = Reconciliation()
        guard !awaitsReview else {
            result.withheld = ["review"]
            result.marked = WorkspaceCapabilityActivation.setAwaitingUpdate(true, on: activation)
            return result
        }
        let current = componentIDs(of: package)
        let currentSet = Set(current)
        let stateIDs = Set(activation.configKeys.compactMap(PluginActivation.componentID(ofSettingKey:)))
            .union(activation.secretSettingKeys.compactMap(PluginActivation.componentID(ofSettingKey:)))
            .union(activation.bindings.filter { !$0.isDeleted }.map(\.componentID))
            .union(activation.overriddenComponentIDs)
        let known = Set(activation.knownComponentIDs).union(stateIDs)
        let renames = renames(in: package)
        // Two live predecessors of one component can't both hand over their
        // settings, accounts and secrets: Update refuses, the automatic pass
        // leaves the activation alone.
        let livePredecessors = Dictionary(grouping: renames.filter { known.contains($0.key) && !currentSet.contains($0.key) }, by: \.value)
        if let (new, _) = livePredecessors.first(where: { $0.value.count > 1 }) {
            guard mode == .release else {
                result.withheld = [new]
                result.marked = WorkspaceCapabilityActivation.setAwaitingUpdate(true, on: activation)
                return result
            }
            throw UpdateError.ambiguousRename(component: new)
        }

        // A rename destination whose namespace is still journaled for
        // deletion (a component removed earlier whose cleanup failed) is
        // cleared first, so the renamed one never inherits its old values.
        let pendingDestinations = renames.sorted(by: { $0.key < $1.key }).compactMap { old, new -> String? in
            guard known.contains(old), !currentSet.contains(old), new.hasPrefix("skill:"),
                  let spec = package.skills.first(where: { CapabilityResourceOrigin.componentID(for: $0) == new }) else { return nil }
            let kept = Set(activation.secretSettingKeys
                .filter { PluginActivation.componentID(ofSettingKey: $0) == new }
                .map { String($0.dropFirst(new.count + 1)) })
            let settled = PluginSecretCleanupOutbox.settleRenameDestination(
                PluginRuntimeProjection.derivedID(of: activation, componentID: new),
                keys: spec.environmentKeys, kept: kept, modelContext: modelContext ?? activation.modelContext,
                clean: { persistence.deleteAllSecretsReportingResult(skillID: $0) }
            ) { persistence.deleteSecret(key: $0, skillID: PluginRuntimeProjection.derivedID(of: activation, componentID: new)) }
            return settled ? nil : new
        }
        if let blocked = pendingDestinations.first {
            guard mode == .release else {
                result.withheld = pendingDestinations
                result.marked = WorkspaceCapabilityActivation.setAwaitingUpdate(true, on: activation)
                return result
            }
            throw UpdateError.secretCleanupPending(key: blocked)
        }

        for (old, new) in renames.sorted(by: { $0.key < $1.key })
        where known.contains(old) && !currentSet.contains(old) {
            if old.hasPrefix("skill:"), let spec = package.skills.first(where: { CapabilityResourceOrigin.componentID(for: $0) == new }) {
                let oldID = PluginRuntimeProjection.derivedID(of: activation, componentID: old)
                let newID = PluginRuntimeProjection.derivedID(of: activation, componentID: new)
                let before = copied.count
                // The old namespace is released below, so the automatic pass
                // also carries the secrets the successor stopped declaring:
                // they stay recorded on it, and only Update deletes them.
                let undeclared = mode == .release ? [] : activation.secretSettingKeys
                    .filter { PluginActivation.componentID(ofSettingKey: $0) == old }
                    .map { String($0.dropFirst(old.count + 1)) }
                try copySecrets(of: spec, alsoCopying: undeclared, from: oldID, to: newID, persistence: persistence, copied: &copied)
                result.copied += copied[before...]
                retargetSkill(oldID, to: newID, in: workspace)
                result.released.append(oldID)
            }
            WorkspaceCapabilityActivation.moveComponentState(from: old, to: new, on: activation)
            result.moved = true
        }

        let beforeAccounts = copied.count
        result.changedAccountIDs = syncOwnedAccounts(of: activation, to: package, store: connectorStore, copied: &copied)
        if !result.changedAccountIDs.isEmpty { result.moved = true }
        result.copied += copied[beforeAccounts...]

        let dropped = known.subtracting(currentSet).subtracting(renames.keys).sorted()
        let staleKeys = staleSettings(of: activation, in: package)
        let templatesInSync = PluginTemplateSync.isInSync(package, in: workspace)
        // A secret the definition declares again whose old value is still
        // journaled for deletion is cleared before the definition is taken.
        let unsettled = PluginSecretCleanupOutbox.settleRedeclared(
            unrecordedSecrets(of: activation, in: package), modelContext: modelContext ?? activation.modelContext
        ) { persistence.deleteSecret(key: $0.key, skillID: $0.skillID) }
        let secretsSettled = unsettled.isEmpty
        if !secretsSettled, mode == .release {
            throw UpdateError.secretCleanupPending(key: Set(unsettled.map(\.key)).sorted().joined(separator: ", "))
        }
        // A definition replaced under the version the activation accepted
        // (other content, same version) is the person's to take: Update.
        let changedInPlace = activation.recordedVersion == package.version
            && PluginDefinitionDigest.matches(activation.recordedDigest, package) == false
        if mode == .automatic, !dropped.isEmpty || !staleKeys.isEmpty || !templatesInSync || !secretsSettled || changedInPlace {
            result.withheld = dropped + staleKeys.map(\.settingKey) + (templatesInSync ? [] : ["templates"])
                + (secretsSettled ? [] : ["secrets"]) + (changedInPlace ? ["definition"] : [])
            // The renames moved state onto components the definition still
            // declares: the history names those now.
            WorkspaceCapabilityActivation.setKnownComponents(
                activation.knownComponentIDs.map { renames[$0] ?? $0 },
                on: activation
            )
            result.marked = WorkspaceCapabilityActivation.setAwaitingUpdate(true, on: activation)
            return result
        }

        // A row replacing a component this definition no longer declares is
        // the workspace's own again (a shared one back on its lists) before
        // the component's state goes, as at Add.
        WorkspaceCapabilityActivation.releaseUndeclaredOverrides(on: activation, declaring: current, in: workspace)
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

    /// Whether `package` still awaits its review in `workspace`: a draft no
    /// approval covers, an approval for another digest, or a pack's review
    /// gate.
    static func awaitsReview(_ package: PluginPackage, in workspace: Workspace, approvalRecords: [CapabilityApprovalRecord]) -> Bool {
        CapabilityCatalogPolicy.decision(
            for: package, context: .currentUser(workspace: workspace, approvalRecords: approvalRecords)
        ).blockers.contains { blocker in
            switch blocker {
            case .draftRequiresApproval, .approvalDigestMismatch, .packPolicyReviewRequired: true
            default: false
            }
        }
    }

    /// What an activation records for the definition it accepted: its
    /// content, never where the copy came from (`PluginDefinitionDigest`).
    static func digest(of package: PluginPackage) -> String {
        PluginDefinitionDigest.content(of: package)
    }

    /// Puts back what `copied` overwrote, newest first. Returns the keys it
    /// couldn't put back, for the caller to report.
    @discardableResult
    static func undo(
        _ copied: [CopiedSecret], secrets: (any SkillSecretPersisting.Type)? = nil, connectorStore: SecretStore? = nil
    ) -> [String] {
        let persistence = secrets ?? SkillSecretSeam.required
        var unrestored: [String] = []
        for secret in copied.reversed() {
            let restored = if let account = secret.account {
                account.undo(store: connectorStore ?? SecretStoreSeam.required)
            } else if let previous = secret.previousValue {
                persistence.saveSecretValue(previous, key: secret.key, skillID: secret.skillID, skillName: "", allowUserInteraction: false)
            } else {
                persistence.deleteSecret(key: secret.key, skillID: secret.skillID)
            }
            if !restored, !unrestored.contains(secret.key) { unrestored.append(secret.key) }
        }
        return unrestored
    }

    // MARK: - Private

    /// Brings the account rows this plugin created to its connector
    /// declarations: credential and setting keys it now declares are added,
    /// and its description, icon and notes follow; one stamped with a
    /// component this one `replaces` is stamped with this one, so its
    /// creator's declaration is found by ID (`PluginRuntimeProjection`).
    /// What the person entered (URL, auth method, values) is kept. Each
    /// setting moved into the Keychain is recorded in `copied`, for the
    /// caller to `undo` if its save fails. Returns the rows it changed.
    @discardableResult
    static func syncOwnedAccounts(
        of activation: PluginActivation, to package: PluginPackage, store: SecretStore? = nil, copied: inout [CopiedSecret]
    ) -> Set<UUID> {
        let store = store ?? SecretStoreSeam.required
        var changed = Set<UUID>()
        for declared in package.connectors {
            // Settings only a bundled definition keeps plain; any other is a
            // credential key. A row that still holds one as plain text moves
            // it to the Keychain here; one whose move fails keeps it.
            let spec = PluginConnectorFieldTrust.asStored(declared, in: package)
            let moved = PluginConnectorFieldTrust.settingsStoredAsCredentials(of: declared, in: package)
            let componentID = CapabilityResourceOrigin.componentID(for: spec)
            let predecessors = Set(CapabilityResourceOrigin.replacedComponentIDs(for: spec))
            for account in activation.accounts(forComponent: componentID)
            where !account.isDeleted && account.originPackageID == package.id {
                var touched = !account.moveSettingsToKeychain(moved, store: store) { copied.append(CopiedSecret($0)) }.isEmpty
                if let stamp = account.originComponentID, predecessors.contains(stamp) {
                    account.originComponentID = componentID
                    touched = true
                }
                for hint in spec.credentialHints where !account.credentialKeys.contains(hint.key)
                    && !(moved.contains(hint.key) && account.configKeys.contains(hint.key)) {
                    while account.credentialValues.count < account.credentialKeys.count { account.credentialValues.append("") }
                    account.credentialKeys.append(hint.key)
                    account.credentialValues.append("")
                    touched = true
                }
                for hint in spec.configHints where !account.configKeys.contains(hint.key) {
                    while account.configValues.count < account.configKeys.count { account.configValues.append("") }
                    account.configKeys.append(hint.key)
                    account.configValues.append("")
                    touched = true
                }
                if account.connectorDescription != spec.description { account.connectorDescription = spec.description; touched = true }
                if account.icon != spec.icon { account.icon = spec.icon; touched = true }
                if account.notes != spec.notes { account.notes = spec.notes; touched = true }
                if account.originPackageVersion != package.version { account.originPackageVersion = package.version; touched = true }
                if touched {
                    account.updatedAt = Date()
                    changed.insert(account.id)
                }
            }
        }
        return changed
    }

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

    /// The secret settings `package` declares that `activation` doesn't
    /// record a value for, by namespace.
    private static func unrecordedSecrets(of activation: PluginActivation, in package: PluginPackage) -> [StaleSecret] {
        package.skills.flatMap { skill -> [StaleSecret] in
            let componentID = CapabilityResourceOrigin.componentID(for: skill)
            return skill.environmentKeys
                .filter { Skill.isSecretEnvironmentKey($0) }
                .filter { !activation.secretSettingKeys.contains(PluginActivation.settingKey(componentID: componentID, key: $0)) }
                .map { StaleSecret(key: $0, skillID: PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)) }
        }
    }

    /// Copies each secret setting of a renamed skill (and the recorded
    /// `extraKeys`) into its successor's namespace, unless the successor
    /// already has a value of its own.
    private static func copySecrets(
        of spec: PluginSkill,
        alsoCopying extraKeys: [String] = [],
        from oldID: UUID,
        to newID: UUID,
        persistence: any SkillSecretPersisting.Type,
        copied: inout [CopiedSecret]
    ) throws {
        let declared = spec.environmentKeys.filter(Skill.isSecretEnvironmentKey)
        for key in declared + extraKeys.filter({ !declared.contains($0) }) {
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
            WorkspaceCapabilityActivation.rewriteDefaultSkills(of: template, in: workspace, rewrite)
        }
        for schedule in workspace.schedules where schedule.skillIDs.contains(oldID) {
            schedule.skillIDs = rewrite(schedule.skillIDs)
        }
    }
}
