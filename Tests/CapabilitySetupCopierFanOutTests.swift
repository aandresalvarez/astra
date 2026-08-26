import Testing
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Counts every `load` so a test can assert how *much* the copier asks the
/// keychain, not just what it concludes. Each load is a synchronous securityd
/// round trip in production, so the count is the cost.
private final class CountingSecretStore: SecretStore {
    private var storage: [String: [String: String]] = [:]
    private(set) var loads: [(key: String, entityID: String)] = []

    func load(key: String, entityID: String) -> String? {
        loads.append((key, entityID))
        return storage[entityID]?[key]
    }

    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        storage[entityID, default: [:]][key] = value
        return true
    }

    @discardableResult
    func delete(key: String, entityID: String) -> Bool {
        storage[entityID]?[key] = nil
        return true
    }

    func deleteAll(entityID: String) {
        storage[entityID] = nil
    }

    func exists(key: String, entityID: String) -> Bool {
        storage[entityID]?[key] != nil
    }
}

/// Guards the fan-out of `CapabilitySetupCopier` against the two shapes that
/// made it expensive enough to hang the New Workspace sheet: probing rows the
/// main loop has already swept, and probing the same key twice in a row.
///
/// Both are invisible when the keychain works — a hit returns early — and
/// unbounded when it does not, which is exactly when the app can least afford
/// them. Behaviour is asserted alongside the counts in every test here, because
/// the point is that the cheaper sweep finds the same credentials.
@Suite("CapabilitySetupCopier fan-out")
@MainActor
struct CapabilitySetupCopierFanOutTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeRedcapPackage() -> PluginPackage {
        PluginPackage(
            id: "redcap-workflow",
            name: "REDCap",
            icon: "chart.bar.doc.horizontal",
            description: "d",
            author: "ASTRA",
            category: "Research",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [
                PluginConnector(
                    name: "REDCap",
                    serviceType: "redcap",
                    icon: "network",
                    description: "REDCap connector",
                    baseURL: "https://redcap.example.edu/api/",
                    authMethod: "api_key",
                    credentialHints: [.init(key: "REDCAP_API_TOKEN", hint: "Token")],
                    configHints: [],
                    notes: ""
                )
            ],
            localTools: [],
            templates: []
        )
    }

    @Test("An enabled global connector the main loop already swept is not swept again")
    func matchedGlobalConnectorIsNotProbedTwice() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let global = Connector(
            name: "REDCap",
            serviceType: "redcap",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        global.isGlobal = true
        global.credentialKeys = ["REDCAP_API_TOKEN"]
        context.insert(global)

        let workspace = Workspace(name: "Source", primaryPath: NSTemporaryDirectory())
        workspace.enabledGlobalConnectorIDs = [global.id.uuidString]
        workspace.enabledCapabilityIDs = ["redcap-workflow"]
        context.insert(workspace)
        try context.save()

        let store = CountingSecretStore()
        let copier = CapabilitySetupCopier(secretStore: store)
        _ = copier.copySetup(
            from: workspace,
            packages: [makeRedcapPackage()],
            globalConnectors: [global]
        )

        // The legacy-recovery pass used to re-probe any enabled global whose
        // service type matched — but a matching global is, by definition,
        // already in `matchingConnectors`, and the main loop sweeps it over a
        // superset of these keys and a superset of these entity IDs. Control
        // only reaches the legacy pass when that superset returned nil, so the
        // repeat cannot find anything. On a store with three enabled globals it
        // was a third of every load the sweep issued.
        let duplicates = Dictionary(grouping: store.loads, by: { "\($0.entityID)|\($0.key)" })
            .filter { $0.value.count > 1 }
        #expect(
            duplicates.isEmpty,
            "The copier probed the same (entityID, key) more than once: \(duplicates.keys.sorted())"
        )
    }

    @Test("Skipping the already-swept global still copies its credential")
    func matchedGlobalConnectorCredentialIsStillFound() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let global = Connector(
            name: "REDCap",
            serviceType: "redcap",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        global.isGlobal = true
        global.credentialKeys = ["REDCAP_API_TOKEN"]
        context.insert(global)

        let workspace = Workspace(name: "Source", primaryPath: NSTemporaryDirectory())
        workspace.enabledGlobalConnectorIDs = [global.id.uuidString]
        workspace.enabledCapabilityIDs = ["redcap-workflow"]
        context.insert(workspace)
        try context.save()

        let store = CountingSecretStore()
        store.save(
            key: "REDCAP_API_TOKEN",
            value: "tok-abc",
            entityID: KeychainSecretStore.connectorEntityID(for: global.id),
            label: nil
        )

        let summary = CapabilitySetupCopier(secretStore: store).copySetup(
            from: workspace,
            packages: [makeRedcapPackage()],
            globalConnectors: [global]
        )

        let inputs = try #require(summary.inputsByPackageID["redcap-workflow"])
        #expect(inputs.credentialInputs["REDCAP_API_TOKEN"] == "tok-abc")
    }

    @Test("A dangling global connector ID is still recovered, and each key probed once")
    func danglingGlobalConnectorIsStillRecovered() throws {
        let container = try makeContainer()
        let context = container.mainContext

        // An ID with no live row: the connector was deleted and its keychain
        // entries outlived it. This is the only case the legacy pass can still
        // learn something from, so the skip above must not reach it.
        let danglingID = UUID()
        let workspace = Workspace(name: "Source", primaryPath: NSTemporaryDirectory())
        workspace.enabledGlobalConnectorIDs = [danglingID.uuidString]
        workspace.enabledCapabilityIDs = ["redcap-workflow"]
        context.insert(workspace)
        try context.save()

        let store = CountingSecretStore()
        store.save(
            key: "REDCAP_API_TOKEN",
            value: "tok-orphan",
            entityID: KeychainSecretStore.connectorEntityID(for: danglingID),
            label: nil
        )

        let summary = CapabilitySetupCopier(secretStore: store).copySetup(
            from: workspace,
            packages: [makeRedcapPackage()],
            globalConnectors: []
        )

        let inputs = try #require(summary.inputsByPackageID["redcap-workflow"])
        #expect(inputs.credentialInputs["REDCAP_API_TOKEN"] == "tok-orphan")

        // Every credential hint the catalog ships is already uppercase, so the
        // unattributed candidate triple `[key, key.uppercased(), key.lowercased()]`
        // held two distinct keys and three probes. `copyKeyCandidates` dedups
        // its own equivalent; this one did not.
        let duplicates = Dictionary(grouping: store.loads, by: { "\($0.entityID)|\($0.key)" })
            .filter { $0.value.count > 1 }
        #expect(
            duplicates.isEmpty,
            "The dangling-ID pass repeated a probe: \(duplicates.keys.sorted())"
        )
    }
}

/// The cheap scalar key that decides when the expensive sweep above re-runs.
/// Getting it wrong is silent: the list simply keeps showing what it decided
/// once, and the sweep it is protecting never happens again.
@Suite("Copyable capability setup key")
@MainActor
struct CopyableCapabilitySetupKeyTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeRedcapPackage() -> PluginPackage {
        PluginPackage(
            id: "redcap-workflow",
            name: "REDCap",
            icon: "chart.bar.doc.horizontal",
            description: "d",
            author: "ASTRA",
            category: "Research",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [
                PluginConnector(
                    name: "REDCap",
                    serviceType: "redcap",
                    icon: "network",
                    description: "REDCap connector",
                    baseURL: "https://redcap.example.edu/api/",
                    authMethod: "api_key",
                    credentialHints: [.init(key: "REDCAP_API_TOKEN", hint: "Token")],
                    configHints: [],
                    notes: ""
                )
            ],
            localTools: [],
            templates: []
        )
    }

    /// A global connector is one of the inputs the summary is derived from, so
    /// a credential filled in on one has to move the key. It neither adds nor
    /// removes a row, so identity alone could not see it — and the sheet went
    /// on offering a setup it had already decided was incomplete.
    @Test("Filling in a global connector's credential moves the key")
    func globalConnectorTimestampMovesTheKey() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Lab", primaryPath: "/tmp/lab")
        let connector = Connector(
            name: "REDCap", serviceType: "redcap", icon: "tablecells",
            baseURL: "https://redcap.stanford.edu/api/", authMethod: "api_key")
        context.insert(workspace)
        context.insert(connector)

        let before = CopyableCapabilitySetupResolver.key(
            sources: [workspace], globalConnectors: [connector])
        // What a credential write does: `recordCredentialSaveResult` stamps it.
        connector.updatedAt = connector.updatedAt.addingTimeInterval(60)
        let after = CopyableCapabilitySetupResolver.key(
            sources: [workspace], globalConnectors: [connector])

        #expect(before != after)
    }

    @Test("The key is stable when nothing the summary reads has changed")
    func keyIsStableAcrossReads() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Lab", primaryPath: "/tmp/lab")
        let connector = Connector(
            name: "REDCap", serviceType: "redcap", icon: "tablecells",
            baseURL: "https://redcap.stanford.edu/api/", authMethod: "api_key")
        context.insert(workspace)
        context.insert(connector)

        #expect(
            CopyableCapabilitySetupResolver.key(sources: [workspace], globalConnectors: [connector])
                == CopyableCapabilitySetupResolver.key(sources: [workspace], globalConnectors: [connector])
        )
    }

    /// The list the key protects. Offering the workspace being set up as a
    /// source to copy from is offering it its own values back, and a workspace
    /// with nothing saved is a menu row that does nothing.
    @Test("Install sources exclude the destination and anything with nothing to copy")
    func installSourcesExcludeTheDestinationAndTheEmpty() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = CountingSecretStore()

        let global = Connector(
            name: "REDCap", serviceType: "redcap",
            baseURL: "https://redcap.example.edu/api/", authMethod: "api_key")
        global.isGlobal = true
        global.credentialKeys = ["REDCAP_API_TOKEN"]
        context.insert(global)
        store.save(
            key: "REDCAP_API_TOKEN",
            value: "tok-abc",
            entityID: KeychainSecretStore.connectorEntityID(for: global.id),
            label: nil
        )

        // Configured identically, so only the exclusion can tell them apart.
        let source = Workspace(name: "Source", primaryPath: NSTemporaryDirectory())
        let destination = Workspace(name: "Destination", primaryPath: NSTemporaryDirectory())
        for workspace in [source, destination] {
            workspace.enabledGlobalConnectorIDs = [global.id.uuidString]
            workspace.enabledCapabilityIDs = ["redcap-workflow"]
            context.insert(workspace)
        }
        let empty = Workspace(name: "Empty", primaryPath: NSTemporaryDirectory())
        context.insert(empty)
        try context.save()

        let resolved = CopyableCapabilitySetupResolver.installSources(
            for: makeRedcapPackage(),
            excluding: destination.id,
            sources: [source, destination, empty],
            globalConnectors: [global],
            copier: CapabilitySetupCopier(secretStore: store)
        )

        #expect(resolved.map(\.name) == ["Source"])
        #expect(resolved.first?.inputs.credentialInputs["REDCAP_API_TOKEN"] == "tok-abc")
    }

    /// Two callers keying on the same rows for different packages must not
    /// share a key, or installing one would reuse the other's resolved list.
    @Test("A prefix separates callers that key on something else as well")
    func prefixSeparatesCallers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Lab", primaryPath: "/tmp/lab")
        context.insert(workspace)

        let plain = CopyableCapabilitySetupResolver.key(sources: [workspace], globalConnectors: [])
        let prefixed = CopyableCapabilitySetupResolver.key(
            prefix: "redcap-workflow", sources: [workspace], globalConnectors: [])

        #expect(plain != prefixed)
        #expect(prefixed.hasPrefix("redcap-workflow|"))
    }
}
