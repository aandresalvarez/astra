import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Prepares an unreachable credential generation. Only the account's model
/// reference is published by the caller's existing durable operation commit.
@MainActor
final class ConnectorCredentialGenerationTransaction {
    enum LegacyHandling { case migrate, preservePending }
    enum SettingConflicts { case preserve, reject }
    struct LegacyField: Equatable {
        let key: String
        let value: String
    }
    enum Failure: Error, LocalizedError {
        case changedAccount, readFailed(String), copyFailed(String)
        case legacyCredentialRejected(String, ConnectorCredentialAdmissionVerdict)
        case conflictingLegacyValues(String)
        case legacySourceNotSaved, legacyFieldsNeedReview
        var errorDescription: String? {
            switch self {
            case .legacyFieldsNeedReview: return "Review this account's unmatched legacy fields before migrating its credentials."
            case .legacySourceNotSaved: return "Save this account's legacy fields before migrating its credentials."
            case .changedAccount: return "The account changed before its credentials could be prepared. Retry."
            case .readFailed(let key): return "Couldn't read the saved \(key). Unlock the credential store and retry."
            case .copyFailed(let key): return "Couldn't preserve the saved \(key) for this account. Retry."
            case .conflictingLegacyValues(let key):
                return "There are different saved values for \(key). Replace or remove that credential before migrating this account."
            case .legacyCredentialRejected(let key, let verdict):
                return verdict.message(forKey: key) ?? "The saved \(key) must be corrected before migrating this account."
            }
        }
    }
    let namespaceID: UUID
    /// Existing model-owned migration debt. Editor actions retain these raw
    /// fields without admitting or transporting them as credentials.
    let pendingLegacyFields: [String: [LegacyField]]
    /// Only these exact source fields can be removed after staging. A caller
    /// cannot erase a newer unsaved value just because its key is the same.
    let settledSettingFields: [LegacyField]
    var accountID: UUID { staged.connectorID }
    private var writeAttempted = false
    private let previous: ConnectorKeychainCleanup?
    private let staged: ConnectorKeychainCleanup
    private let journal: ConnectorCredentialGenerationJournal?
    let lease: ConnectorCredentialGenerationJournal.Lease?

    private init(namespaceID: UUID, previous: ConnectorKeychainCleanup?, staged: ConnectorKeychainCleanup,
                 pendingLegacyFields: [String: [LegacyField]], settledSettingFields: [LegacyField], journal: ConnectorCredentialGenerationJournal?, lease: ConnectorCredentialGenerationJournal.Lease?) {
        self.namespaceID = namespaceID
        self.pendingLegacyFields = pendingLegacyFields
        self.settledSettingFields = settledSettingFields
        self.previous = previous
        self.staged = staged
        self.journal = journal
        self.lease = lease
    }

    func noteWriteAttempt() { writeAttempted = true }

    static func prepare(
        account: Connector, isNew: Bool, keeping keys: Set<String>, replacing: Set<String>, modelContext: ModelContext,
        declaredFormats: [String: [ConnectorCredentialFormat]] = [:],
        migratingSettings: Set<String> = [],
        settingConflicts: SettingConflicts = .preserve,
        legacyHandling: LegacyHandling = .migrate,
        copying sourceAccount: Connector? = nil,
        lease: ConnectorCredentialGenerationJournal.Lease? = nil
    ) throws -> Self {
        guard account.modelContext === modelContext, !account.isDeleted else { throw Failure.changedAccount }
        let journal = try ConnectorCredentialGenerationJournal(modelContext: modelContext)
        let heldLease = try journal?.acquireLease(reusing: lease)
        _ = try journal?.pending() // Reject unreadable ownership before any vault write.
        let saved = ModelContext(modelContext.container)
        saved.autosaveEnabled = false
        let sourceAccount = sourceAccount ?? account
        let copying = sourceAccount !== account
        guard sourceAccount.modelContext === modelContext, !sourceAccount.isDeleted else { throw Failure.changedAccount }
        guard sourceAccount.credentialValues.dropFirst(sourceAccount.credentialKeys.count).allSatisfy({ $0.isEmpty }),
              sourceAccount.configValues.dropFirst(sourceAccount.configKeys.count).allSatisfy({ $0.isEmpty })
        else { throw Failure.legacyFieldsNeedReview }
        if copying {
            let destinationID = account.id
            var destination = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == destinationID })
            destination.fetchLimit = 1
            guard isNew, try saved.fetch(destination).isEmpty,
                  modelContext.insertedModelsArray.contains(where: { ($0 as? Connector) === account })
            else { throw Failure.changedAccount }
        }
        let accountID = sourceAccount.id
        var query = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == accountID })
        query.fetchLimit = 2
        let rows = try saved.fetch(query)
        guard rows.count <= 1 else { throw Failure.changedAccount }
        let stored = rows.first
        if let stored {
            guard (copying || !isNew),
                  ConnectorSavedAccountState.matches(stored, sourceAccount)
            else { throw Failure.changedAccount }
        } else {
            guard !copying, isNew || modelContext.insertedModelsArray.contains(where: { ($0 as? Connector) === account })
            else { throw Failure.changedAccount }
        }
        // Legacy promotion consumes durable source rows. Newly inserted or
        // changed plain fields must be saved before an automatic cutover.
        if !migratingSettings.isEmpty {
            guard let stored, stored.configKeys == sourceAccount.configKeys,
                  stored.configValues == sourceAccount.configValues else { throw Failure.legacySourceNotSaved }
        }
        let namespaceID = UUID()
        let old = copying ? nil : stored?.keychainCleanup
        var staged = account.keychainCleanup
        staged.credentialNamespaceID = namespaceID
        let source = ConnectorSecretFacts(connector: stored ?? account)
        let target = ConnectorSecretFacts(id: source.id, name: source.name, serviceType: source.serviceType,
            baseURL: source.baseURL, originPackageID: source.originPackageID, originComponentID: source.originComponentID,
            credentialNamespaceID: namespaceID)
        var copies: [(String, String)] = []
        var legacyValues: [(String, String)] = []
        var pendingLegacyFields: [String: [LegacyField]] = [:]
        var settledSettingFields: [LegacyField] = []
        if let stored {
            // A legacy plain setting being promoted can have a newer vault
            // value without a credential marker. Preserve that value too, but
            // never probe arbitrary undeclared/retired keys: only current
            // saved fields explicitly retained by this transaction are owners.
            let plainKeys = stored.configKeys.indices.compactMap { index -> String? in
                guard index < stored.configValues.count, !stored.configValues[index].isEmpty else { return nil }
                return stored.configKeys[index]
            }
            let sourceKeys = Set((stored.credentialKeys + plainKeys).map(ConnectorCredentialKey.canonical))
            for key in sourceKeys.intersection(keys).sorted()
            where !replacing.contains(key) {
                let plainFields = migratingSettings.contains(key) ? stored.configKeys.indices.compactMap { index -> LegacyField? in
                    guard ConnectorCredentialKey.same(stored.configKeys[index], key) else { return nil }
                    return LegacyField(key: stored.configKeys[index],
                        value: index < stored.configValues.count ? stored.configValues[index] : "")
                } : []
                switch ConnectorSecretSeam.required.readCredential(key: key, facts: source, store: KeychainSecretStore()) {
                case .value(let value):
                    if case .reject = settingConflicts,
                       plainFields.contains(where: { !$0.value.isEmpty && $0.value != value }) {
                        throw Failure.conflictingLegacyValues(key)
                    }
                    settledSettingFields += plainFields.filter { $0.value.isEmpty || $0.value == value }
                    copies.append((key, value))
                case .missing:
                    var fields = stored.credentialKeys.indices.compactMap { index -> LegacyField? in
                        guard ConnectorCredentialKey.same(stored.credentialKeys[index], key) else { return nil }
                        return LegacyField(key: stored.credentialKeys[index],
                            value: index < stored.credentialValues.count ? stored.credentialValues[index] : "")
                    }
                    fields += plainFields
                    let candidates = Set(fields.map(\.value).filter { !$0.isEmpty })
                    if case .preservePending = legacyHandling, !candidates.isEmpty {
                        pendingLegacyFields[key] = fields
                        continue
                    }
                    guard candidates.count <= 1 else { throw Failure.conflictingLegacyValues(key) }
                    if let value = candidates.first {
                        legacyValues.append((key, value))
                        settledSettingFields += plainFields
                    }
                case .unavailable: throw Failure.readFailed(key)
                }
            }
        }
        // The accepted definition may not yet be installed. Validate every
        // declaration for a shared account instead of consulting only the
        // previous library entry or silently choosing its first binding.
        for (key, value) in legacyValues {
            for format in declaredFormats[key] ?? [] {
                let decision = ConnectorCredentialAdmission.evaluate(key: key, value: value,
                    serviceType: source.serviceType, declaredFormat: format)
                guard decision.isAdmitted else { throw Failure.legacyCredentialRejected(key, decision.verdict) }
            }
        }
        if let journal, let heldLease { try journal.record([staged] + (old.map { [$0] } ?? []), lease: heldLease) }
        let prepared = Self(namespaceID: namespaceID, previous: old, staged: staged,
            pendingLegacyFields: pendingLegacyFields, settledSettingFields: settledSettingFields, journal: journal, lease: heldLease)
        for (key, value) in copies {
            // An opaque value already admitted to this same logical account.
            prepared.noteWriteAttempt()
            guard ConnectorSecretSeam.required.saveCredential(value, key: key, facts: target, allowUserInteraction: false) else {
                prepared.discard()
                throw Failure.copyFailed(key)
            }
        }
        // The isolated saved context is never persisted. It gives admission
        // the actual account identity and store scope while writing only to
        // the unpublished namespace. Unadmitted legacy plaintext must not use
        // the opaque copy path for already-accepted Keychain values above.
        if let stored, !legacyValues.isEmpty {
            stored.credentialNamespaceID = namespaceID
            for (key, value) in legacyValues {
                prepared.noteWriteAttempt()
                switch stored.saveCredentialChecked(key: key, value: value, allowUserInteraction: false,
                    declaredFormat: declaredFormats[key]?.first) {
                case .saved: break
                case .rejected(let verdict):
                    prepared.discard()
                    throw Failure.legacyCredentialRejected(key, verdict)
                case .keychainWriteFailed:
                    prepared.discard()
                    throw Failure.copyFailed(key)
                }
            }
        }
        return prepared
    }

    func completed() {
        if let journal, let lease { journal.forget([staged], lease: lease) }
    }

    /// Called only after a proved noncommit or before any model cutover.
    func discard() {
        let facts = ConnectorSecretFacts(id: staged.connectorID, name: staged.name, serviceType: staged.serviceType,
            baseURL: staged.baseURL, originPackageID: staged.originPackageID, originComponentID: staged.originComponentID,
            credentialNamespaceID: staged.credentialNamespaceID)
        let cleared = !writeAttempted || ConnectorSecretSeam.required.deleteAllCredentialsReportingResult(facts: facts, sparing: [])
        if let journal, let lease {
            journal.forget((previous.map { [$0] } ?? []) + (cleared ? [staged] : []), lease: lease)
        }
    }
}
