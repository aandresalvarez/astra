import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Capability Library", .serialized)
struct CapabilityLibraryTests {
    @Test("capability directory is isolated by app channel")
    func channelDirectoriesAreIsolated() {
        let dev = CapabilityLibrary.capabilitiesDirectory(for: .development).path
        let prod = CapabilityLibrary.capabilitiesDirectory(for: .production).path
        let beta = CapabilityLibrary.capabilitiesDirectory(for: .beta).path

        #expect(dev.contains("AstraDev/Capabilities"))
        #expect(prod.contains("Astra/Capabilities"))
        #expect(beta.contains("AstraBeta/Capabilities"))
        #expect(dev != prod)
        #expect(dev != beta)
        #expect(prod != beta)
    }

    @Test("install writes and reloads capability package")
    func installAndLoadPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "stanford.bigquery/analyst",
            name: "BigQuery Analyst",
            icon: "folder",
            description: "Analyze BigQuery datasets",
            author: "Stanford",
            category: "Data",
            tags: ["bigquery"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(package)

        let expectedURL = library.packageURL(for: package.id)
        #expect(expectedURL.lastPathComponent == "stanford-bigquery-analyst.json")
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        #expect(library.installedPackages().map(\.id) == [package.id])
        #expect(library.installedVersion(of: package.id) == "1.0.0")
        #expect(library.installedPackage(id: package.id)?.sourceMetadata == .localLibrary())
    }

    @Test("install writes package folder manifest and copies declared icon asset")
    func installWritesPackageFolderManifestAndCopiesDeclaredIconAsset() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-asset-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        let sourceIcon = sourceAssets.appendingPathComponent("icon.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
            .write(to: sourceIcon)

        let library = CapabilityLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        var package = PluginPackage(
            id: "local.asset-package",
            name: "Asset Package",
            icon: "puzzlepiece.extension",
            iconDescriptor: .asset("assets/icon.svg", fallbackSystemName: "puzzlepiece.extension"),
            description: "Package with a local asset icon",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        package.sourceMetadata = .localLibrary()

        try library.install(CapabilityPackageSource(package: package, manifestURL: nil, assetRootURL: sourceRoot))

        let manifestURL = library.packageManifestURL(for: package.id)
        let copiedIconURL = manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("assets/icon.svg")
        let installed = try #require(library.installedPackage(id: package.id))

        #expect(manifestURL.lastPathComponent == "capability.json")
        #expect(manifestURL.deletingLastPathComponent().lastPathComponent == "local-asset-package")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: copiedIconURL.path))
        #expect(library.packageStorageURL(for: package.id) == manifestURL)
        #expect(installed.iconDescriptor == .asset("assets/icon.svg", fallbackSystemName: "puzzlepiece.extension"))
        #expect(installed.sourceMetadata?.url?.resolvingSymlinksInPath() == manifestURL.resolvingSymlinksInPath())
    }

    @Test("installing plain package over asset package removes stale package folder")
    func installingPlainPackageOverAssetPackageRemovesStalePackageFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-asset-to-json-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
            .write(to: sourceAssets.appendingPathComponent("icon.svg"))

        let library = CapabilityLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let assetPackage = PluginPackage(
            id: "local.storage-switch",
            name: "Storage Switch",
            icon: "puzzlepiece.extension",
            iconDescriptor: .asset("assets/icon.svg", fallbackSystemName: "puzzlepiece.extension"),
            description: "Asset package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        var plainPackage = assetPackage
        plainPackage.version = "2.0.0"
        plainPackage.icon = "star"
        plainPackage.iconDescriptor = .systemSymbol("star")

        try library.install(CapabilityPackageSource(package: assetPackage, manifestURL: nil, assetRootURL: sourceRoot))
        let manifestURL = library.packageManifestURL(for: assetPackage.id)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        try library.install(plainPackage)

        let jsonURL = library.packageURL(for: plainPackage.id)
        let installed = try #require(library.installedPackage(id: plainPackage.id))
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(!FileManager.default.fileExists(atPath: manifestURL.deletingLastPathComponent().path))
        #expect(library.packageStorageURL(for: plainPackage.id) == jsonURL)
        #expect(installed.version == "2.0.0")
        #expect(installed.iconDescriptor == .systemSymbol("star"))
    }

    @Test("installing asset package over plain package removes stale JSON file")
    func installingAssetPackageOverPlainPackageRemovesStaleJSONFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-json-to-asset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
            .write(to: sourceAssets.appendingPathComponent("icon.svg"))

        let library = CapabilityLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let plainPackage = PluginPackage(
            id: "local.storage-switch",
            name: "Storage Switch",
            icon: "star",
            description: "Plain package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        var assetPackage = plainPackage
        assetPackage.version = "2.0.0"
        assetPackage.icon = "puzzlepiece.extension"
        assetPackage.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: "puzzlepiece.extension")

        try library.install(plainPackage)
        let jsonURL = library.packageURL(for: plainPackage.id)
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        try library.install(CapabilityPackageSource(package: assetPackage, manifestURL: nil, assetRootURL: sourceRoot))

        let manifestURL = library.packageManifestURL(for: assetPackage.id)
        let installed = try #require(library.installedPackage(id: assetPackage.id))
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(library.packageStorageURL(for: assetPackage.id) == manifestURL)
        #expect(installed.version == "2.0.0")

        try library.removePackage(id: assetPackage.id, trustedBuiltInIDs: [])
        #expect(library.installedPackage(id: assetPackage.id, trustedBuiltInIDs: []) == nil)
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))
    }

    @Test("storage snapshot removes fresh package folder after rollback")
    func storageSnapshotRemovesFreshPackageFolderAfterRollback() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-asset-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
            .write(to: sourceAssets.appendingPathComponent("icon.svg"))

        let library = CapabilityLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let package = PluginPackage(
            id: "local.asset-rollback",
            name: "Asset Rollback",
            icon: "puzzlepiece.extension",
            iconDescriptor: .asset("assets/icon.svg", fallbackSystemName: "puzzlepiece.extension"),
            description: "Package with a local asset icon",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        let snapshot = library.makePackageStorageSnapshot(for: package.id)

        try library.install(CapabilityPackageSource(package: package, manifestURL: nil, assetRootURL: sourceRoot))
        let manifestURL = library.packageManifestURL(for: package.id)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        library.restorePackageStorage(snapshot)

        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: manifestURL.deletingLastPathComponent().path))
    }

    @Test("runtime package definitions refresh when installed package directory changes")
    func runtimePackageDefinitionsRefreshWhenLibraryChanges() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-runtime-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let first = PluginPackage(
            id: "stanford.first-runtime-cache",
            name: "First Runtime Cache",
            icon: "folder",
            description: "First package",
            author: "Stanford",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let second = PluginPackage(
            id: "stanford.second-runtime-cache",
            name: "Second Runtime Cache",
            icon: "folder",
            description: "Second package",
            author: "Stanford",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(first)
        let firstIDs = Set(CapabilityRuntimeResourceMatcher.packageDefinitions(library: library).map(\.id))
        #expect(firstIDs.contains(first.id))
        #expect(!firstIDs.contains(second.id))

        try library.install(second)
        let secondIDs = Set(CapabilityRuntimeResourceMatcher.packageDefinitions(library: library).map(\.id))
        #expect(secondIDs.contains(first.id))
        #expect(secondIDs.contains(second.id))
    }

    @Test("Package definitions fingerprint changes when an asset-backed directory package is installed")
    func packageDefinitionsFingerprintChangesForDirectoryPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
            .write(to: sourceAssets.appendingPathComponent("icon.svg"))

        let library = CapabilityLibrary(directory: root.appendingPathComponent("library", isDirectory: true))
        let beforeFingerprint = CapabilityRuntimeResourceMatcher.packageDefinitionsFingerprint(library: library)

        var package = PluginPackage(
            id: "local.fingerprint-asset-package",
            name: "Fingerprint Asset Package",
            icon: "puzzlepiece.extension",
            iconDescriptor: .asset("assets/icon.svg", fallbackSystemName: "puzzlepiece.extension"),
            description: "Directory-backed package for fingerprint coverage",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        package.sourceMetadata = .localLibrary()
        try library.install(CapabilityPackageSource(package: package, manifestURL: nil, assetRootURL: sourceRoot))

        let afterInstallFingerprint = CapabilityRuntimeResourceMatcher.packageDefinitionsFingerprint(library: library)
        #expect(afterInstallFingerprint != beforeFingerprint)
    }

    @Test("in-memory enabledPackages filters to enabled ids, merges built-ins, and de-dupes")
    func enabledPackagesInMemoryOverloadResolvesWithoutFilesystem() throws {
        let builtInID = try #require(PluginCatalog.builtInPackages.first?.id)

        let enabledLocal = makeTestPackage(id: "local.test/enabled", name: "Enabled Local")
        let disabledLocal = makeTestPackage(id: "local.test/disabled", name: "Disabled Local")

        let workspace = Workspace(name: "Matcher", primaryPath: "/tmp/matcher")
        workspace.enabledCapabilityIDs = [enabledLocal.id, builtInID]

        // The list intentionally repeats `enabledLocal` to exercise de-dupe and
        // omits the built-in entirely so it can only appear via the merge.
        let definitions = [enabledLocal, enabledLocal, disabledLocal]
        let ids = CapabilityRuntimeResourceMatcher
            .enabledPackages(for: workspace, in: definitions)
            .map(\.id)

        // enabled-id filtering: only enabled ids, never the disabled one.
        #expect(Set(ids) == [enabledLocal.id, builtInID])
        #expect(!ids.contains(disabledLocal.id))
        // de-dupe: the duplicated injected package resolves exactly once.
        #expect(ids.filter { $0 == enabledLocal.id }.count == 1)
        // built-in merge: an enabled built-in resolves even when not injected.
        #expect(ids.contains(builtInID))
    }

    @Test("in-memory enabledPackages returns empty when nothing is enabled or workspace is nil")
    func enabledPackagesInMemoryOverloadHandlesEmptyCases() {
        let workspace = Workspace(name: "Empty", primaryPath: "/tmp/empty")
        let definitions = [makeTestPackage(id: "local.test/unused", name: "Unused")]

        #expect(CapabilityRuntimeResourceMatcher.enabledPackages(for: workspace, in: definitions).isEmpty)
        #expect(CapabilityRuntimeResourceMatcher.enabledPackages(for: nil, in: PluginCatalog.builtInPackages).isEmpty)
    }

    @Test("enabled packages excludes pack-disabled runtime packages")
    func enabledPackagesExcludesPackDisabledRuntimePackages() {
        let allowed = makeTestPackage(id: "local.test/allowed", name: "Allowed")
        let disabled = makeTestPackage(id: "local.test/disabled", name: "Disabled")
        let workspace = Workspace(name: "Policy", primaryPath: "/tmp/policy")
        workspace.enabledCapabilityIDs = [allowed.id, disabled.id]
        let packPolicy = Self.policy(restrictions: [
            AstraPackPolicyRestriction(
                id: "disable-local",
                contributionKind: "capabilityPackage",
                action: "disableCapability",
                effect: "restrict",
                targetID: disabled.id
            )
        ])

        let ids = CapabilityRuntimeResourceMatcher
            .enabledPackages(for: workspace, in: [allowed, disabled], packPolicy: packPolicy)
            .map(\.id)

        #expect(ids.contains(allowed.id))
        #expect(!ids.contains(disabled.id))
    }

    @Test("in-memory enabled packages applies only supplied pack policy")
    func inMemoryEnabledPackagesAppliesOnlySuppliedPackPolicy() {
        let disabled = makeTestPackage(id: "local.test/disabled", name: "Disabled")
        let workspace = Workspace(name: "Policy", primaryPath: "/tmp/policy")
        workspace.enabledCapabilityIDs = [disabled.id]
        workspace.enabledPackIDs = ["astra.pack.policy-test"]
        let packPolicy = Self.policy(restrictions: [
            AstraPackPolicyRestriction(
                id: "disable-local",
                contributionKind: "capabilityPackage",
                action: "disableCapability",
                effect: "restrict",
                targetID: disabled.id
            )
        ])

        let withoutSuppliedPolicy = CapabilityRuntimeResourceMatcher.enabledPackages(
            for: workspace,
            in: [disabled]
        )
        let withSuppliedPolicy = CapabilityRuntimeResourceMatcher.enabledPackages(
            for: workspace,
            in: [disabled],
            packPolicy: packPolicy
        )

        #expect(withoutSuppliedPolicy.map(\.id) == [disabled.id])
        #expect(withSuppliedPolicy.isEmpty)
    }

    @Test("enabled packages avoids approval store reads without pack review gates")
    func enabledPackagesAvoidsApprovalStoreReadsWithoutPackReviewGates() {
        let disabled = makeTestPackage(id: "local.test/disabled", name: "Disabled")
        let workspace = Workspace(name: "Policy", primaryPath: "/tmp/policy")
        workspace.enabledCapabilityIDs = [disabled.id]
        let disabledPolicy = Self.policy(restrictions: [
            AstraPackPolicyRestriction(
                id: "disable-local",
                contributionKind: "capabilityPackage",
                action: "disableCapability",
                effect: "restrict",
                targetID: disabled.id
            )
        ])
        var approvalLoadCount = 0
        CapabilityRuntimeResourceMatcher.withApprovalRecordsLoaderForTesting({
            approvalLoadCount += 1
            return []
        }) {
            let packages = CapabilityRuntimeResourceMatcher.enabledPackages(
                for: workspace,
                in: [disabled],
                packPolicy: disabledPolicy
            )

            #expect(packages.isEmpty)
            #expect(approvalLoadCount == 0)

            let gated = makeTestPackage(id: "local.test/gated", name: "Gated")
            workspace.enabledCapabilityIDs = [gated.id]
            let gatedPolicy = Self.policy(restrictions: [
                AstraPackPolicyRestriction(
                    id: "review-gated",
                    contributionKind: "capabilityPackage",
                    action: "requireReviewGate",
                    effect: "restrict",
                    targetID: gated.id
                )
            ])
            let gatedPackages = CapabilityRuntimeResourceMatcher.enabledPackages(
                for: workspace,
                in: [gated],
                packPolicy: gatedPolicy
            )

            #expect(gatedPackages.isEmpty)
            #expect(approvalLoadCount == 1)
        }
    }

    @Test("enabled packages honors pack review gate approvals")
    func enabledPackagesHonorsPackReviewGateApprovals() throws {
        let gated = makeTestPackage(id: "local.test/gated", name: "Gated")
        let workspace = Workspace(name: "Review Gate", primaryPath: "/tmp/review-gate")
        workspace.enabledCapabilityIDs = [gated.id]
        let packPolicy = Self.policy(restrictions: [
            AstraPackPolicyRestriction(
                id: "review-gated",
                contributionKind: "capabilityPackage",
                action: "requireReviewGate",
                effect: "restrict",
                targetID: gated.id
            )
        ])
        let approved = CapabilityApprovalRecord(
            packageID: gated.id,
            packageVersion: gated.version,
            status: .approved,
            approvedBy: "Vertical Owner",
            approvedAt: Date(),
            reviewNotes: "Approved.",
            sourceDigest: try CapabilityApprovalDigest.digest(for: gated)
        )

        let blocked = CapabilityRuntimeResourceMatcher.enabledPackages(
            for: workspace,
            in: [gated],
            approvalRecords: [],
            packPolicy: packPolicy
        )
        let allowed = CapabilityRuntimeResourceMatcher.enabledPackages(
            for: workspace,
            in: [gated],
            approvalRecords: [approved],
            packPolicy: packPolicy
        )

        #expect(blocked.isEmpty)
        #expect(allowed.map(\.id) == [gated.id])
    }

    private static func policy(restrictions: [AstraPackPolicyRestriction]) -> PackResolvedPolicy {
        AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [
                AstraPackManifest(
                    formatVersion: 1,
                    id: "astra.pack.policy-test",
                    name: "Policy Test",
                    version: "1.0.0",
                    coreAPIVersion: "1.0",
                    description: "Policy test pack.",
                    policyRestrictions: restrictions
                )
            ])
        )
    }

    private func makeTestPackage(id: String, name: String) -> PluginPackage {
        PluginPackage(
            id: id,
            name: name,
            icon: "folder",
            description: "",
            author: "Test",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: CapabilityGovernance(approvalStatus: .approved)
        )
    }

    @Test("package URLs stay inside library for malicious IDs")
    func packageURLStaysInsideLibraryForMaliciousIDs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "../../Library/Secrets;rm -rf",
            name: "Malicious ID",
            icon: "folder",
            description: "Should not escape the library",
            author: "Test",
            category: "Security",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(package)

        let url = library.packageURL(for: package.id)
        #expect(url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(url.lastPathComponent == "Library-Secrets-rm--rf.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("Library").path))
    }

    @Test("remove deletes local package file")
    func removeDeletesLocalPackageFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-remove-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "stanford.local.remove",
            name: "Local Remove",
            icon: "trash",
            description: "Local capability",
            author: "Stanford",
            category: "Local",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        try library.install(package)

        let removed = try library.removePackage(id: package.id)

        #expect(removed.id == package.id)
        #expect(library.installedPackage(id: package.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: library.packageURL(for: package.id).path))
    }

    @Test("remove rejects built-in package file")
    func removeRejectsBuiltInPackageFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-remove-builtin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let package = PluginPackage(
            id: "stanford.builtin",
            name: "Built In",
            icon: "lock",
            description: "Built-in capability",
            author: "ASTRA",
            category: "Built In",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        try library.install(package, sourceMetadata: .builtIn())

        do {
            _ = try library.removePackage(id: package.id, trustedBuiltInIDs: [package.id])
            Issue.record("Built-in package removal should fail")
        } catch let error as CapabilityLibrary.RemovalError {
            #expect(error == .builtInPackage(package.name))
        }

        #expect(library.installedPackage(id: package.id, trustedBuiltInIDs: [package.id]) != nil)
    }

    @Test("catalog refresh does not restore removed local package")
    func catalogRefreshDoesNotRestoreRemovedLocalPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-remove-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let local = PluginPackage(
            id: "stanford.local.refresh",
            name: "Local Refresh",
            icon: "arrow.clockwise",
            description: "Local capability",
            author: "Stanford",
            category: "Local",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let builtIn = PluginPackage(
            id: "stanford.builtin.refresh",
            name: "Built In Refresh",
            icon: "checkmark.seal",
            description: "Built-in capability",
            author: "ASTRA",
            category: "Built In",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(local)
        try library.syncApprovedPackages([builtIn])
        _ = try library.removePackage(id: local.id)
        try library.syncApprovedPackages([builtIn])

        let ids = Set(library.installedPackages().map(\.id))
        #expect(!ids.contains(local.id))
        #expect(ids.contains(builtIn.id))
    }

    @Test("capability library detects package updates")
    func detectsPackageUpdates() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-updates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let installed = PluginPackage(
            id: "stanford.bigquery.analyst",
            name: "BigQuery Analyst",
            icon: "folder",
            description: "Analyze BigQuery datasets",
            author: "Stanford",
            category: "Data",
            tags: ["bigquery"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        var newer = installed
        newer.version = "1.1.0"
        var same = installed
        same.version = "1.0.0"

        try library.install(installed)

        #expect(library.hasUpdate(for: newer))
        #expect(!library.hasUpdate(for: same))
    }

    @Test("seed approved packages writes package files and preserves newer built-in versions")
    func seedApprovedPackages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        var approved = PluginPackage(
            id: "stanford.approved",
            name: "Approved",
            icon: "checkmark.seal",
            description: "Approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        try library.seedApprovedPackages([approved])

        #expect(library.installedPackages().map(\.id) == ["stanford.approved"])
        #expect(library.installedPackage(id: approved.id, trustedBuiltInIDs: [approved.id])?.sourceMetadata == .builtIn())
        // Without an entry in the trusted built-in set, self-declared
        // built-in source metadata is clamped back to local on load.
        #expect(library.installedPackage(id: approved.id)?.sourceMetadata == .localLibrary())

        approved.version = "0.9.0"
        try library.seedApprovedPackages([approved])
        #expect(library.installedPackage(id: approved.id)?.version == "1.0.0")
    }

    @Test("seed approved packages overwrites same-version built-in drift")
    func seedApprovedPackagesOverwritesSameVersionDrift() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-seed-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let approved = PluginPackage(
            id: "stanford.approved.drift",
            name: "Approved Drift",
            icon: "checkmark.seal",
            description: "Canonical approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: [BrowserSiteAdapterID.github]
        )
        var stale = approved
        stale.name = "Old Approved Drift"
        stale.description = "Stale same-version capability"
        stale.browserAdapters = []

        try library.install(stale, sourceMetadata: .builtIn())
        try library.seedApprovedPackages([approved])

        let installed = try #require(library.installedPackage(id: approved.id, trustedBuiltInIDs: [approved.id]))
        #expect(installed.name == "Approved Drift")
        #expect(installed.description == "Canonical approved capability")
        #expect(installed.browserAdapters == [BrowserSiteAdapterID.github])
        #expect(installed.sourceMetadata == .builtIn())
    }

    @Test("seed approved packages prevents local packages from shadowing approved IDs")
    func seedApprovedPackagesOverwritesLocalIDShadow() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-seed-shadow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let approved = PluginPackage(
            id: "stanford.approved.shadow",
            name: "Approved Shadow",
            icon: "checkmark.seal",
            description: "Canonical approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        var localShadow = approved
        localShadow.name = "Local Shadow"
        localShadow.description = "Should not shadow the approved built-in ID"
        localShadow.version = "99.0.0"

        try library.install(localShadow, sourceMetadata: .localLibrary())
        try library.seedApprovedPackages([approved])

        let installed = try #require(library.installedPackage(id: approved.id, trustedBuiltInIDs: [approved.id]))
        #expect(installed.name == "Approved Shadow")
        #expect(installed.version == "1.0.0")
        #expect(installed.sourceMetadata == .builtIn())
    }

    @Test("sync approved packages removes stale built-in packages but keeps local packages")
    func syncApprovedPackages() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = CapabilityLibrary(directory: root)
        let kept = PluginPackage(
            id: "stanford.kept",
            name: "Kept",
            icon: "checkmark.seal",
            description: "Approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let staleBuiltIn = PluginPackage(
            id: "stanford.stale",
            name: "Stale",
            icon: "xmark.seal",
            description: "Removed approved capability",
            author: "Stanford",
            category: "Approved",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )
        let local = PluginPackage(
            id: "stanford.local",
            name: "Local",
            icon: "person",
            description: "User-created capability",
            author: "Stanford",
            category: "Local",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: []
        )

        try library.install(staleBuiltIn, sourceMetadata: .builtIn())
        try library.install(local, sourceMetadata: .localLibrary())
        try library.syncApprovedPackages([kept])

        let ids = Set(library.installedPackages().map(\.id))
        #expect(ids.contains("stanford.kept"))
        #expect(ids.contains("stanford.local"))
        #expect(!ids.contains("stanford.stale"))
    }

    @Test("bundled approved capability folder exposes repo-maintained packages")
    func bundledApprovedCapabilityFolder() throws {
        let packages = ApprovedCapabilityBundle.packages()
        let expectedIDs: Set<String> = [
            "gcloud-workflow",
            "github-workflow",
            "google-drive-browser",
            "google-workspace",
            "jira-workflow",
            "mcp-smoke-test",
            "redcap-workflow",
            "security-auditor",
            "stanford-apple-mail",
            "stanford-healthcare-graph-mail"
        ]

        #expect(ApprovedCapabilityBundle.bundledDirectory()?.lastPathComponent == "Capabilities")
        #expect(Set(packages.map(\.id)) == expectedIDs)
        #expect(packages.allSatisfy { $0.sourceMetadata?.kind == "built-in" })
        for id in ["gcloud-workflow", "github-workflow", "google-drive-browser", "jira-workflow"] {
            let package = try #require(packages.first { $0.id == id })
            #expect(package.iconDescriptor.kind == .asset)
            #expect(package.sourceMetadata?.url?.lastPathComponent.hasSuffix(".json") == true)
            if case .asset(let url) = CapabilityIconPresentation.make(for: package).kind {
                #expect(FileManager.default.fileExists(atPath: url.path))
            } else {
                Issue.record("\(id) should resolve its bundled icon asset.")
            }
        }
        #expect(packages.first { $0.id == "gcloud-workflow" }?.connectors.map(\.name) == ["Google Cloud"])
        #expect(packages.first { $0.id == "github-workflow" }?.connectors.isEmpty == true)
        #expect(packages.first { $0.id == "github-workflow" }?.browserAdapters.isEmpty == true)
        #expect(packages.first { $0.id == "github-workflow" }?.localTools.isEmpty == true)
        #expect(packages.first { $0.id == "github-workflow" }?.prerequisites.map(\.binary) == ["gh", "gh"])
        let github = packages.first { $0.id == "github-workflow" }
        #expect(github?.version == "2.1.4")
        #expect(github?.governance.externalEffects == [.readOnly])
        #expect(github?.skills.first?.allowedTools.contains("Bash") == false)
        #expect(github?.skills.first?.disallowedTools.contains("Bash") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("mcp__astra_host__github") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("astra_host-github") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("via Bash") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh search issues") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh search prs --author \"@me\"") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("Do not pipe JSON into `python3 - <<'PY'`") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh api /search/issues") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("do not use `--jq` or `-q`") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("Prefer `--json` with `--jq`") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("This capability is read-only") == true)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh issue create") == false)
        #expect(github?.skills.first?.behaviorInstructions.contains("gh pr comment") == false)
        #expect(packages.first { $0.id == "google-drive-browser" }?.browserAdapters == [BrowserSiteAdapterID.googleDrive])
        #expect(packages.first { $0.id == "redcap-workflow" }?.connectors.map(\.baseURL) == ["https://redcap.stanford.edu/api/"])
        #expect(packages.first { $0.id == "redcap-workflow" }?.connectors.first?.credentialHints.map(\.key) == ["REDCAP_API_TOKEN"])
        #expect(packages.first { $0.id == "stanford-apple-mail" }?.connectors.isEmpty == true)
        #expect(packages.first { $0.id == "stanford-apple-mail" }?.localTools.map(\.command) == ["stanford-apple-mail"])
        #expect(packages.first { $0.id == "stanford-healthcare-graph-mail" }?.connectors.isEmpty == true)
        #expect(packages.first { $0.id == "stanford-healthcare-graph-mail" }?.localTools.map(\.command) == ["stanford-graph-mail"])
    }

    @Test("seed approved packages copies bundled icon assets")
    func seedApprovedPackagesCopiesBundledIconAssets() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-seed-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let package = try #require(ApprovedCapabilityBundle.packages().first { $0.id == "github-workflow" })

        try library.syncApprovedPackages([package])

        let manifest = library.packageManifestURL(for: package.id)
        let icon = manifest.deletingLastPathComponent().appendingPathComponent("assets/github.svg")
        let installed = try #require(library.installedPackage(id: package.id, trustedBuiltInIDs: [package.id]))
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: icon.path))
        #expect(installed.iconDescriptor.kind == .asset)
        #expect(installed.iconDescriptor.value == "assets/github.svg")
        #expect(installed.iconDescriptor.fallbackSystemName == package.icon)
        #expect(installed.sourceMetadata?.kind == "built-in")
        #expect(installed.sourceMetadata?.url?.resolvingSymlinksInPath() == manifest.resolvingSymlinksInPath())
    }

    @Test("seed approved packages repairs matching built-in manifest with missing icon asset")
    func seedApprovedPackagesRepairsMissingBundledIconAsset() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-repair-missing-asset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let package = try #require(ApprovedCapabilityBundle.packages().first { $0.id == "gcloud-workflow" })

        try library.syncApprovedPackages([package])
        let manifest = library.packageManifestURL(for: package.id)
        let icon = manifest.deletingLastPathComponent().appendingPathComponent("assets/google-cloud.svg")
        #expect(FileManager.default.fileExists(atPath: icon.path))

        try FileManager.default.removeItem(at: icon)
        try library.syncApprovedPackages([package])

        let repaired = try #require(library.installedPackage(id: package.id, trustedBuiltInIDs: [package.id]))
        #expect(FileManager.default.fileExists(atPath: icon.path))
        #expect(repaired.iconDescriptor.kind == .asset)
        #expect(repaired.iconDescriptor.value == "assets/google-cloud.svg")
        #expect(repaired.sourceMetadata?.url?.resolvingSymlinksInPath() == manifest.resolvingSymlinksInPath())
    }

    @Test("reinstalling installed asset package preserves its icon asset")
    func reinstallingInstalledAssetPackagePreservesIconAsset() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-reinstall-asset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let package = try #require(ApprovedCapabilityBundle.packages().first { $0.id == "gcloud-workflow" })

        try library.syncApprovedPackages([package])
        let installed = try #require(library.installedPackage(id: package.id, trustedBuiltInIDs: [package.id]))
        let manifest = library.packageManifestURL(for: package.id)
        let icon = manifest.deletingLastPathComponent().appendingPathComponent("assets/google-cloud.svg")
        #expect(FileManager.default.fileExists(atPath: icon.path))

        try library.install(installed)

        let reloaded = try #require(library.installedPackage(id: package.id, trustedBuiltInIDs: [package.id]))
        #expect(FileManager.default.fileExists(atPath: icon.path))
        #expect(reloaded.sourceMetadata?.url?.resolvingSymlinksInPath() == manifest.resolvingSymlinksInPath())
    }

    @Test("sync approved packages removes stale built-in package folders")
    func syncApprovedPackagesRemovesStaleBuiltInPackageFolders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-stale-asset-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let current = try #require(ApprovedCapabilityBundle.packages().first { $0.id == "github-workflow" })
        var stale = current
        stale.id = "removed-built-in-asset"
        stale.name = "Removed Built-in Asset"

        try library.install(stale, sourceMetadata: .builtIn())
        let staleManifest = library.packageManifestURL(for: stale.id)
        #expect(FileManager.default.fileExists(atPath: staleManifest.path))

        try library.syncApprovedPackages([current])

        #expect(!FileManager.default.fileExists(atPath: staleManifest.deletingLastPathComponent().path))
    }

    @Test("resource bundle resolver exposes app icon")
    func resourceBundleResolverExposesAppIcon() throws {
        let bundle = AstraResourceBundle.current
        let iconURL = try #require(bundle.url(forResource: "AppIcon", withExtension: "icns"))
        #expect(FileManager.default.fileExists(atPath: iconURL.path))
    }
}
