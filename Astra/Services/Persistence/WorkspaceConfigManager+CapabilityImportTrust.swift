import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// What a workspace config file may decide about capabilities on import.
///
/// A config import used to take the file's word for which capability packages
/// and packs are enabled, which shared rows are turned on, and which package a
/// skill, connector, tool or template came from. Origin stamps decide which
/// row speaks for a package at runtime (`CapabilityRuntimeResourceMatcher`
/// ranks an owned row above a name match) and whether host-control GitHub
/// routing turns on, so a forged stamp outranked the real package. The
/// `.astra-share` import never trusted any of this; a config the user picks
/// now gets the same treatment.
extension WorkspaceConfigManager {
    public enum CapabilityImportTrustPolicy: Sendable {
        /// The workspace's own mirror, re-read by launch recovery: restore
        /// exactly what was recorded.
        case preserveRecordedState
        /// A file the user chose: keep only what this machine has installed
        /// and approved, and never let it mint shared rows or origin stamps.
        case validate(CapabilityImportVerifier)
    }

    /// This machine's installed capability state, taken once per import. Built
    /// in the app target, which owns the library and approval store.
    public struct CapabilityImportVerifier: Sendable {
        public var approvedPackageIDs: Set<String>
        public var installedPackageIDs: Set<String>
        public var availablePackIDs: Set<String>
        /// Each installed package's component IDs; an imported activation
        /// keeps settings, bindings and overrides only for these.
        public var declaredComponentIDs: [String: Set<String>]
        /// Each installed package's approval digest. An imported activation
        /// recorded against another digest (another copy under the same ID)
        /// stays off and brings none of its settings or accounts.
        public var installedDigests: [String: String]
        /// Where each installed package's copy came from, by plugin ID, in
        /// `InstalledPluginRef.source`'s form; a local copy has no entry. An
        /// imported activation from another source (or a local one where
        /// the copy here came from a source) stays off like another copy.
        public var installedSources: [String: String]
        /// Each installed package's content digest (`PluginDefinitionDigest`),
        /// which activations record now: one recorded against it accepted
        /// this definition, from whichever copy. `installedDigests` judges a
        /// file written before content digests.
        public var installedContentDigests: [String: String]
        /// Each installed package's connector components, by component ID.
        /// An imported account is bound only to a component it is an account
        /// of (`acceptsAccount`).
        public var connectorComponents: [String: [String: ConnectorComponent]]

        public struct ConnectorComponent: Sendable, Equatable {
            public var serviceType: String
            public var name: String

            public init(serviceType: String, name: String) {
                self.serviceType = serviceType
                self.name = name
            }
        }

        public init(
            approvedPackageIDs: Set<String>,
            installedPackageIDs: Set<String>,
            availablePackIDs: Set<String>,
            declaredComponentIDs: [String: Set<String>] = [:],
            installedDigests: [String: String] = [:],
            installedContentDigests: [String: String] = [:],
            installedSources: [String: String] = [:],
            connectorComponents: [String: [String: ConnectorComponent]] = [:]
        ) {
            self.approvedPackageIDs = approvedPackageIDs
            self.installedPackageIDs = installedPackageIDs
            self.availablePackIDs = availablePackIDs
            self.declaredComponentIDs = declaredComponentIDs
            self.installedDigests = installedDigests
            self.installedSources = installedSources
            self.installedContentDigests = installedContentDigests
            self.connectorComponents = connectorComponents
        }

        /// True when `connector` may be bound as an account of the installed
        /// plugin's connector component: a row the import created (a shared
        /// row it reused keeps its credentials to itself) for the component's
        /// own service. A custom or unnamed service also needs the
        /// component's name. Projection and readiness trust a binding, so the
        /// file's word that a row is an account is never enough.
        /// `createdByImport` marks a shared row this same import created for
        /// another workspace (`ImportSession`): created, so it may be bound.
        public func acceptsAccount(
            _ connector: Connector, componentID: String, pluginID: String, createdByImport: Bool = false
        ) -> Bool {
            guard createdByImport || !connector.isGlobal,
                  let component = connectorComponents[pluginID]?[componentID] else { return false }
            func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let service = normalized(component.serviceType)
            guard normalized(connector.serviceType) == service else { return false }
            guard service.isEmpty || service == "custom" else { return true }
            return !normalized(component.name).isEmpty && normalized(connector.name) == normalized(component.name)
        }
    }

    /// What `.validate` removed from an import, for the result and the audit.
    public struct CapabilityImportTrustReport: Sendable, Equatable {
        public var capabilitiesUnavailable: [String] = []
        public var packsUnavailable: [String] = []
        public var pluginsUnavailable: [String] = []
        /// Plugins whose activation names another copy than the installed
        /// one: kept, but off and without their details.
        public var pluginsChanged: [String] = []
        /// Of `pluginsChanged`, those whose copy matches but whose source
        /// differs: recorded from one source, installed here from another
        /// (or locally).
        public var pluginsFromAnotherSource: [String] = []
        /// The workspace's own mirror (`.preserveRecordedState`): plugins
        /// whose installed copy came from another source than the one the
        /// activation recorded (a source, another source, or a local copy).
        /// Held as a pending import, not activated (T5).
        public var pluginsHeldOnRecovery: [String] = []
        public var unknownSharedRowIDs: [String] = []
        public var originStampsStripped = 0
        public var sharedRowsLocalized = 0

        public init() {}

        public var isEmpty: Bool { self == CapabilityImportTrustReport() }

        public var auditFields: [String: String] {
            [
                "capabilities_unavailable": capabilitiesUnavailable.joined(separator: ", "),
                "packs_unavailable": packsUnavailable.joined(separator: ", "),
                "plugins_unavailable": pluginsUnavailable.joined(separator: ", "),
                "plugins_changed": pluginsChanged.joined(separator: ", "),
                "plugins_from_another_source": pluginsFromAnotherSource.joined(separator: ", "),
                "plugins_held_on_recovery": pluginsHeldOnRecovery.joined(separator: ", "),
                "unknown_shared_row_count": String(unknownSharedRowIDs.count),
                "origin_stamps_stripped": String(originStampsStripped),
                "shared_rows_localized": String(sharedRowsLocalized)
            ]
        }
    }

    /// The enablement state a config asks for.
    static func requestedActivation(from config: WorkspaceConfig) -> WorkspaceCapabilityActivationState {
        WorkspaceCapabilityActivationState(
            capabilityIDs: config.enabledCapabilityIDs ?? [],
            packIDs: config.enabledPackIDs ?? [],
            globalSkillIDs: config.enabledGlobalSkillIDs ?? [],
            globalConnectorIDs: config.enabledGlobalConnectorIDs ?? [],
            globalToolIDs: config.enabledGlobalToolIDs ?? [],
            pluginIDs: config.installedPlugins?.map(\.id) ?? [],
            pluginVersions: config.installedPlugins?.map(\.version) ?? []
        )
    }

    /// Drops what this machine cannot back: packages that are not installed
    /// and approved, packs it does not have, and shared rows that do not exist
    /// here. Shared rows the import itself reuses are re-enabled afterwards.
    /// True when a chosen file's activation was recorded against the copy
    /// installed here, from the same source: a digest proves the content,
    /// not which source owns its updates (T5). The workspace's own mirror is
    /// always its own copy.
    static func isAcceptedCopy(_ ref: InstalledPluginRef, trust: CapabilityImportTrustPolicy) -> Bool {
        guard case .validate(let verifier) = trust else { return true }
        guard let digest = ref.digest, !digest.isEmpty else { return false }
        let accepted = verifier.installedContentDigests[ref.id] == digest || verifier.installedDigests[ref.id] == digest
        return accepted && isSameSource(ref, verifier: verifier)
    }

    /// The file's source for the activation against the installed copy's;
    /// nil and "local" both mean local.
    static func isSameSource(_ ref: InstalledPluginRef, verifier: CapabilityImportVerifier) -> Bool {
        sourceIdentity(ref.source) == sourceIdentity(verifier.installedSources[ref.id])
    }

    /// A recorded or installed source: nil and "local" both mean local.
    static func sourceIdentity(_ value: String?) -> String? { value == "local" || value?.isEmpty == true ? nil : value }

    /// The workspace's own mirror restores what it recorded, except an
    /// activation whose plugin is installed here from another source than
    /// the copy it recorded came from (a source's copy where it recorded a
    /// local one, a local copy where it recorded a source's, or another
    /// source's): that copy would inherit its settings and accounts, so it
    /// is held as a pending import, kept off (T5). A different digest from
    /// the same source is an Update the activation awaits, as before. Not
    /// installed, or nothing to tell (`installedCopy` nil), restores as
    /// recorded.
    static func heldOnRecovery(
        _ pluginRefs: [InstalledPluginRef], installedCopy: (String) -> PluginInstalledCopy?
    ) -> [String] {
        pluginRefs.compactMap { ref in
            guard case .installed(let source)? = installedCopy(ref.id),
                  sourceIdentity(source) != sourceIdentity(ref.source) else { return nil }
            return ref.id
        }
    }

    @MainActor
    static func reconcile(
        _ state: inout WorkspaceCapabilityActivationState,
        pluginRefs: [InstalledPluginRef],
        trust: CapabilityImportTrustPolicy,
        modelContext: ModelContext,
        report: inout CapabilityImportTrustReport,
        installedCopy: (String) -> PluginInstalledCopy? = PluginSourceIdentitySeam.current.installedCopy
    ) {
        guard case .validate(let verifier) = trust else {
            let held = Set(heldOnRecovery(pluginRefs, installedCopy: installedCopy))
            report.pluginsHeldOnRecovery = state.pluginIDs.filter(held.contains)
            state.capabilityIDs.removeAll(where: held.contains)
            let kept = state.pluginIDs.indices.filter { !held.contains(state.pluginIDs[$0]) }
            state.pluginVersions = kept.map { $0 < state.pluginVersions.count ? state.pluginVersions[$0] : "" }
            state.pluginIDs = kept.map { state.pluginIDs[$0] }
            return
        }
        report.capabilitiesUnavailable = state.capabilityIDs.filter { !verifier.approvedPackageIDs.contains($0) }
        state.capabilityIDs.removeAll { !verifier.approvedPackageIDs.contains($0) }
        report.packsUnavailable = state.packIDs.filter { !verifier.availablePackIDs.contains($0) }
        state.packIDs.removeAll { !verifier.availablePackIDs.contains($0) }
        // Another copy under the same ID never inherits the file's enablement.
        let changed = Set(pluginRefs.filter {
            verifier.installedPackageIDs.contains($0.id) && !isAcceptedCopy($0, trust: trust)
        }.map(\.id))
        report.pluginsChanged = state.pluginIDs.filter(changed.contains)
        report.pluginsFromAnotherSource = report.pluginsChanged.filter { id in
            pluginRefs.contains { $0.id == id && !isSameSource($0, verifier: verifier) }
        }
        state.capabilityIDs.removeAll(where: changed.contains)

        var keptIDs: [String] = []
        var keptVersions: [String] = []
        for (index, id) in state.pluginIDs.enumerated() {
            guard verifier.installedPackageIDs.contains(id) else {
                report.pluginsUnavailable.append(id)
                continue
            }
            keptIDs.append(id)
            keptVersions.append(index < state.pluginVersions.count ? state.pluginVersions[index] : "")
        }
        state.pluginIDs = keptIDs
        state.pluginVersions = keptVersions

        let skills = existingGlobalIDs(of: Skill.self, isGlobal: #Predicate<Skill> { $0.isGlobal }, \.id, modelContext)
        let connectors = existingGlobalIDs(of: Connector.self, isGlobal: #Predicate<Connector> { $0.isGlobal }, \.id, modelContext)
        let tools = existingGlobalIDs(of: LocalTool.self, isGlobal: #Predicate<LocalTool> { $0.isGlobal }, \.id, modelContext)
        report.unknownSharedRowIDs = state.globalSkillIDs.filter { !skills.contains($0) }
            + state.globalConnectorIDs.filter { !connectors.contains($0) }
            + state.globalToolIDs.filter { !tools.contains($0) }
        state.globalSkillIDs.removeAll { !skills.contains($0) }
        state.globalConnectorIDs.removeAll { !connectors.contains($0) }
        state.globalToolIDs.removeAll { !tools.contains($0) }
    }

    @MainActor
    private static func existingGlobalIDs<Model: PersistentModel>(
        of _: Model.Type,
        isGlobal: Predicate<Model>,
        _ id: KeyPath<Model, UUID>,
        _ modelContext: ModelContext
    ) -> Set<String> {
        Set(((try? modelContext.fetch(FetchDescriptor<Model>(predicate: isGlobal))) ?? []).map { $0[keyPath: id].uuidString })
    }

    /// A row created from the file (not an existing row it reused) stays in
    /// this workspace and carries no package provenance under `.validate`.
    /// That includes a skill that only borrows a built-in's name: a reused
    /// built-in is not created here, so a created one is the file's own and
    /// may not mint shared state under a trusted name.
    static func sanitizeCreated(_ skill: Skill, trust: CapabilityImportTrustPolicy, report: inout CapabilityImportTrustReport) {
        guard case .validate = trust else { return }
        if skill.isBuiltIn {
            skill.isBuiltIn = false
        }
        if skill.isGlobal {
            skill.isGlobal = false
            report.sharedRowsLocalized += 1
        }
        if [skill.originPackageID, skill.originPackageVersion, skill.originComponentID,
            skill.originComponentKind, skill.originSourceKind].contains(where: { $0 != nil }) {
            report.originStampsStripped += 1
        }
        skill.originPackageID = nil
        skill.originPackageVersion = nil
        skill.originComponentID = nil
        skill.originComponentKind = nil
        skill.originSourceKind = nil
    }

    static func sanitizeCreated(_ connector: Connector, trust: CapabilityImportTrustPolicy, report: inout CapabilityImportTrustReport) {
        guard case .validate = trust else { return }
        // A selected file cannot select local vault addresses, including
        // historical stable endpoint aliases it might otherwise inherit.
        connector.credentialNamespaceID = UUID()
        if connector.isGlobal {
            connector.isGlobal = false
            report.sharedRowsLocalized += 1
        }
        if [connector.originPackageID, connector.originPackageVersion, connector.originComponentID,
            connector.originComponentKind, connector.originSourceKind].contains(where: { $0 != nil }) {
            report.originStampsStripped += 1
        }
        connector.originPackageID = nil
        connector.originPackageVersion = nil
        connector.originComponentID = nil
        connector.originComponentKind = nil
        connector.originSourceKind = nil
    }

    static func sanitizeCreated(_ tool: LocalTool, trust: CapabilityImportTrustPolicy, report: inout CapabilityImportTrustReport) {
        guard case .validate = trust else { return }
        if tool.isGlobal {
            tool.isGlobal = false
            report.sharedRowsLocalized += 1
        }
        if [tool.originPackageID, tool.originPackageVersion, tool.originComponentID,
            tool.originComponentKind, tool.originSourceKind].contains(where: { $0 != nil }) {
            report.originStampsStripped += 1
        }
        tool.originPackageID = nil
        tool.originPackageVersion = nil
        tool.originComponentID = nil
        tool.originComponentKind = nil
        tool.originSourceKind = nil
    }

    static func sanitizeCreated(_ template: TaskTemplate, trust: CapabilityImportTrustPolicy, report: inout CapabilityImportTrustReport) {
        guard case .validate = trust else { return }
        if [template.originPackageID, template.originPackageVersion, template.originComponentID,
            template.originComponentKind, template.originSourceKind].contains(where: { $0 != nil }) {
            report.originStampsStripped += 1
        }
        template.originPackageID = nil
        template.originPackageVersion = nil
        template.originComponentID = nil
        template.originComponentKind = nil
        template.originSourceKind = nil
    }

    /// A snapshot the import restored as a row (with a fresh ID and a
    /// "(Restored)" name) now names that row, so the resolver does not count
    /// the old snapshot as a second, detached skill.
    static func remapSnapshots(of task: AgentTask, to restored: [String: Skill]) {
        guard !restored.isEmpty else { return }
        task.skillSnapshots = task.skillSnapshots.map { snapshot in
            guard let id = snapshot.id, let row = restored[id] else { return snapshot }
            var remapped = snapshot
            remapped.id = row.id.uuidString
            remapped.credentialNamespaceID = row.credentialNamespaceID
            remapped.name = row.name
            return remapped
        }
    }

}
