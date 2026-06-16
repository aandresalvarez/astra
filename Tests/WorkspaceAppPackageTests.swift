import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace App Packages")
struct WorkspaceAppPackageTests {
    @Test("template export writes portable package files and checksums")
    func templateExportWritesPortablePackageFilesAndChecksums() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)

        let exportedURL = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(exportedURL == packageURL)
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("package.json").path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("storage/schema.json").path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("checksums.json").path))
        #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("storage/data/full").path))

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)
        #expect(report.canInstall)
        #expect(report.package?.packageID == "grocery-template")
        #expect(report.package?.version == "1.2.3")
        #expect(report.package?.requiredContracts.map(\.contract) == ["appStorage.records"])
        #expect(report.installState == .needsPermissionReview)
    }

    @Test("seed data export writes portable typed storage records")
    func seedDataExportWritesPortableTypedStorageRecords() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-seed.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-seed",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )

        let dataURL = packageURL.appendingPathComponent("storage/data/seed/items.jsonl")
        let exportsURL = packageURL.appendingPathComponent("storage/data/exports.json")
        #expect(FileManager.default.fileExists(atPath: dataURL.path))
        #expect(FileManager.default.fileExists(atPath: exportsURL.path))
        #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("storage/data/full/items.jsonl").path))

        let exports = try JSONDecoder().decode(
            [WorkspaceAppPackageDataExport].self,
            from: Data(contentsOf: exportsURL)
        )
        #expect(exports == [
            WorkspaceAppPackageDataExport(
                table: "items",
                policy: .seed,
                path: "storage/data/seed/items.jsonl",
                rowCount: 2
            )
        ])

        let dataText = try String(contentsOf: dataURL, encoding: .utf8)
        #expect(dataText.contains(#""name":"Apples""#))
        #expect(dataText.contains(#""quantity":6"#))

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)
        #expect(report.canInstall)
        #expect(report.package?.exportMode == .templatePlusSeedData)
    }

    @Test("full app export writes records and surfaces a sensitive data warning")
    func fullAppExportWritesRecordsAndSurfacesSensitiveDataWarning() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-full.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-full",
            mode: .fullAppExport,
            appStorageDatabaseURL: databaseURL
        )

        let dataURL = packageURL.appendingPathComponent("storage/data/full/items.jsonl")
        let exportsURL = packageURL.appendingPathComponent("storage/data/exports.json")
        #expect(FileManager.default.fileExists(atPath: dataURL.path))

        let exports = try JSONDecoder().decode(
            [WorkspaceAppPackageDataExport].self,
            from: Data(contentsOf: exportsURL)
        )
        #expect(exports == [
            WorkspaceAppPackageDataExport(
                table: "items",
                policy: .full,
                path: "storage/data/full/items.jsonl",
                rowCount: 2
            )
        ])

        let review = WorkspaceAppPackageImportReviewer.review(packageURL: packageURL)

        #expect(review.canInstall)
        #expect(review.report.package?.exportMode == .fullAppExport)
        #expect(review.report.warnings.contains {
            $0.path == "/package.json/exportMode"
                && $0.message.contains("Full app export")
                && $0.message.contains("sensitive data")
        })
    }

    @Test("record export modes require an app storage database")
    func recordExportModesRequireStorageDatabase() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-seed.astra-app", isDirectory: true)

        #expect(throws: WorkspaceAppPackageError.missingStorageDatabase(.templatePlusSeedData)) {
            try WorkspaceAppPackageService().exportPackage(
                manifest: Self.groceryManifest(),
                to: packageURL,
                mode: .templatePlusSeedData
            )
        }
    }

    @Test("package validation blocks checksum tampering")
    func packageValidationBlocksChecksumTampering() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        try Data(#"{"tampered":true}"#.utf8).write(to: manifestURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/checksums.json/manifest.json" && $0.message.contains("Checksum")
        })
    }

    @Test("package validation blocks credential and absolute path content")
    func packageValidationBlocksCredentialAndAbsolutePathContent() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unsafe.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let unsafeURL = packageURL.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("unsafe.json")
        try FileManager.default.createDirectory(at: unsafeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"api_key":"abc","path":"/Users/alvaro1/private.csv"}"#.utf8)
            .write(to: unsafeURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.path == "/assets/unsafe.json" && $0.message.contains("credential") })
        #expect(report.blockers.contains { $0.path == "/assets/unsafe.json" && $0.message.contains("absolute local path") })
    }

    @Test("package validation marks missing required contracts for dependency mapping")
    func packageValidationMarksMissingRequiredContractsForDependencyMapping() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unmapped.astra-app", isDirectory: true)
        var manifest = Self.groceryManifest()
        manifest.requirements = [
            WorkspaceAppRequirement(
                id: "customRegistry",
                contract: "customRegistry.read",
                operations: ["readRecords"]
            )
        ]
        manifest.sources[0].requirementRef = "customRegistry"
        manifest.actions[0].requirementRef = "customRegistry"
        _ = try WorkspaceAppPackageService().exportPackage(manifest: manifest, to: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(report.canInstall)
        #expect(report.installState == .needsDependencyMapping)
    }

    @Test("package import review exposes identity dependencies permissions and storage")
    func packageImportReviewExposesPackageInspectionFields() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )

        let review = WorkspaceAppPackageImportReviewer.review(packageURL: packageURL)

        #expect(review.canInstall)
        #expect(review.packageName == "Grocery Tracker")
        #expect(review.packageID == "grocery-template")
        #expect(review.version == "1.2.3")
        #expect(review.permissionMode == .draftOnly)
        #expect(review.requiredDependencies.map(\.contract) == ["appStorage.records"])
        #expect(review.storageTables.map(\.name) == ["items"])
        #expect(review.dependencyMappings.count == 1)
        #expect(review.dependencyMappings[0].isMapped)
        #expect(review.dependencyMappings[0].selectedImplementation?.id == "app-storage-native")
        #expect(review.dependencyMappings[0].familyName == "App Storage Records")
    }

    @Test("package import review marks required unmapped dependencies")
    func packageImportReviewMarksRequiredUnmappedDependencies() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unmapped.astra-app", isDirectory: true)
        var manifest = Self.groceryManifest()
        manifest.requirements = [
            WorkspaceAppRequirement(
                id: "customRegistry",
                contract: "customRegistry.read",
                operations: ["readRecords"]
            )
        ]
        manifest.sources[0].requirementRef = "customRegistry"
        manifest.actions[0].requirementRef = "customRegistry"
        _ = try WorkspaceAppPackageService().exportPackage(manifest: manifest, to: packageURL)

        let review = WorkspaceAppPackageImportReviewer.review(packageURL: packageURL)

        #expect(review.report.installState == .needsDependencyMapping)
        #expect(review.hasUnresolvedRequiredDependencies)
        #expect(review.dependencyMappings.count == 1)
        #expect(!review.dependencyMappings[0].isMapped)
        #expect(review.dependencyMappings[0].statusLabel == "Needs mapping")
        #expect(review.dependencyMappings[0].candidateImplementations.isEmpty)
    }

    @Test("package import review includes package declared implementation descriptors")
    func packageImportReviewIncludesPackageDeclaredImplementationDescriptors() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("warehouse.astra-app", isDirectory: true)
        var manifest = Self.groceryManifest()
        manifest.requirements = [
            WorkspaceAppRequirement(
                id: "sourceWarehouse",
                contract: "tabularQuery.read",
                operations: ["describeTable", "runReadOnlyQuery"],
                providerRequired: "warehouseApi"
            )
        ]
        manifest.sources[0].requirementRef = "sourceWarehouse"
        manifest.actions[0].requirementRef = "sourceWarehouse"
        let descriptor = WorkspaceAppContractImplementation(
            id: "warehouse-api-http",
            familyID: "tabularQuery.read",
            provider: "warehouseApi",
            transport: .http,
            operations: ["describeTable", "runReadOnlyQuery"],
            dataAccess: ["externalService"]
        )
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: manifest,
            to: packageURL,
            implementationDescriptors: [descriptor]
        )

        let review = WorkspaceAppPackageImportReviewer.review(packageURL: packageURL)

        #expect(review.report.canInstall)
        #expect(review.report.package?.implementationDescriptors == [descriptor])
        #expect(review.report.installState == .needsPermissionReview)
        #expect(!review.hasUnresolvedRequiredDependencies)
        #expect(review.dependencyMappings.count == 1)
        #expect(review.dependencyMappings[0].selectedImplementation?.id == "warehouse-api-http")
        #expect(review.dependencyMappings[0].selectedImplementation?.transport == .http)
    }

    @Test("package import review exposes unverified trust metadata")
    func packageImportReviewExposesUnverifiedTrustMetadata() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("trusted-grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )
        try Self.updatePackageTrustMetadata(
            at: packageURL,
            trustMetadata: WorkspaceAppPackageTrustMetadata(
                signerIdentity: "ASTRA Team",
                signedAt: Date(timeIntervalSince1970: 1_800_000_000),
                packageDigest: String(repeating: "a", count: 64),
                trustSource: "ASTRA Apps",
                revocationStatus: "notRevoked",
                signatureValidationResult: "unverified"
            )
        )

        let review = WorkspaceAppPackageImportReviewer.review(packageURL: packageURL)

        #expect(review.canInstall)
        #expect(review.trustSummary?.signerIdentity == "ASTRA Team")
        #expect(review.trustSummary?.trustSource == "ASTRA Apps")
        #expect(review.trustSummary?.statusLabel == "Unverified")
        #expect(review.trustSummary?.packageDigest == String(repeating: "a", count: 64))
        #expect(review.report.warnings.contains {
            $0.path == "/package.json/trustMetadata/signatureValidationResult"
                && $0.message.contains("unverified")
        })
    }

    @Test("package validation blocks revoked and invalid trust metadata")
    func packageValidationBlocksRevokedAndInvalidTrustMetadata() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("revoked-grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )
        try Self.updatePackageTrustMetadata(
            at: packageURL,
            trustMetadata: WorkspaceAppPackageTrustMetadata(
                signerIdentity: "ASTRA Team",
                signedAt: nil,
                packageDigest: String(repeating: "b", count: 64),
                trustSource: "ASTRA Apps",
                revocationStatus: "revoked",
                signatureValidationResult: "invalid"
            )
        )

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/package.json/trustMetadata/revocationStatus"
                && $0.message.contains("revoked")
        })
        #expect(report.blockers.contains {
            $0.path == "/package.json/trustMetadata/signatureValidationResult"
                && $0.message.contains("failed")
        })
    }

    @Test("package validation blocks invalid implementation descriptors")
    func packageValidationBlocksInvalidImplementationDescriptors() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("invalid-descriptor.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            implementationDescriptors: [
                WorkspaceAppContractImplementation(
                    id: "invalid/descriptor",
                    familyID: "missing.family",
                    provider: "",
                    transport: .cli,
                    operations: []
                )
            ]
        )

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/package.json/implementationDescriptors/0/id" && $0.message.contains("portable")
        })
        #expect(report.blockers.contains {
            $0.path == "/package.json/implementationDescriptors/0/familyID" && $0.message.contains("unknown contract family")
        })
    }

    @MainActor
    @Test("package import installs forked app with package provenance")
    func packageImportInstallsForkedAppWithPackageProvenance() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Import", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        let result = try WorkspaceAppPackageService().importPackage(
            at: packageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        #expect(result.app.sourcePackageID == "grocery-template")
        #expect(result.app.sourcePackageVersion == "1.2.3")
        #expect(result.app.sourcePackageDigest?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: result.manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: "grocery-tracker"
        )))
    }

    @MainActor
    @Test("package import assigns unique logical IDs for repeated installs")
    func packageImportAssignsUniqueLogicalIDsForRepeatedInstalls() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Import", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        let first = try WorkspaceAppPackageService().importPackage(
            at: packageURL,
            into: workspace,
            modelContext: container.mainContext
        )
        let second = try WorkspaceAppPackageService().importPackage(
            at: packageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        #expect(first.app.logicalID == "grocery-tracker")
        #expect(second.app.logicalID == "grocery-tracker-2")
        #expect(FileManager.default.fileExists(atPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: "grocery-tracker-2"
        )))
    }

    @MainActor
    @Test("package import restores portable seed data into app storage")
    func packageImportRestoresPortableSeedDataIntoAppStorage() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-seed.astra-app", isDirectory: true)
        let sourceDatabaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-seed",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: sourceDatabaseURL
        )

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Import", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        let result = try WorkspaceAppPackageService().importPackage(
            at: packageURL,
            into: workspace,
            modelContext: container.mainContext
        )
        let importedDatabaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: result.app.logicalID
        ))
        let rows = try WorkspaceAppStorageService().records(in: "items", databaseURL: importedDatabaseURL)

        #expect(result.app.sourcePackageID == "grocery-seed")
        #expect(rows.count == 2)
        #expect(rows[0]["id"] == .text("item-1"))
        #expect(rows[0]["name"] == .text("Apples"))
        #expect(rows[0]["quantity"] == .integer(6))
        #expect(rows[1]["id"] == .text("item-2"))
    }

    @MainActor
    @Test("package update checks compare package identity version and digest")
    func packageUpdateChecksComparePackageIdentityVersionAndDigest() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceAppPackageService()
        let originalURL = root.appendingPathComponent("grocery-1.2.astra-app", isDirectory: true)
        let newerURL = root.appendingPathComponent("grocery-1.10.astra-app", isDirectory: true)
        let changedSameVersionURL = root.appendingPathComponent("grocery-1.2-changed.astra-app", isDirectory: true)
        let differentPackageURL = root.appendingPathComponent("other.astra-app", isDirectory: true)

        _ = try service.exportPackage(
            manifest: Self.groceryManifest(),
            to: originalURL,
            packageID: "grocery-template",
            version: "1.2.0"
        )
        _ = try service.exportPackage(
            manifest: Self.groceryManifest(),
            to: newerURL,
            packageID: "grocery-template",
            version: "1.10.0"
        )
        var changedManifest = Self.groceryManifest()
        changedManifest.app.description = "Track pantry inventory with a reviewed template change."
        _ = try service.exportPackage(
            manifest: changedManifest,
            to: changedSameVersionURL,
            packageID: "grocery-template",
            version: "1.2.0"
        )
        _ = try service.exportPackage(
            manifest: Self.groceryManifest(),
            to: differentPackageURL,
            packageID: "another-template",
            version: "9.0.0"
        )

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Updates", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)
        let imported = try service.importPackage(
            at: originalURL,
            into: workspace,
            modelContext: container.mainContext
        )

        let same = service.checkPackageUpdate(for: imported.app, candidatePackageURL: originalURL)
        let newer = service.checkPackageUpdate(for: imported.app, candidatePackageURL: newerURL)
        let changed = service.checkPackageUpdate(for: imported.app, candidatePackageURL: changedSameVersionURL)
        let different = service.checkPackageUpdate(for: imported.app, candidatePackageURL: differentPackageURL)

        #expect(same.status == .sameVersionSameDigest)
        #expect(!same.isUpdateAvailable)
        #expect(!same.requiresReview)
        #expect(newer.status == .updateAvailable)
        #expect(newer.isUpdateAvailable)
        #expect(newer.requiresReview)
        #expect(newer.candidateVersion == "1.10.0")
        #expect(changed.status == .sameVersionDifferentDigest)
        #expect(!changed.isUpdateAvailable)
        #expect(changed.requiresReview)
        #expect(changed.installedDigest != changed.candidateDigest)
        #expect(different.status == .differentPackage)
        #expect(different.candidatePackageID == "another-template")
    }

    @MainActor
    @Test("package update checks classify apps without package provenance")
    func packageUpdateChecksClassifyAppsWithoutPackageProvenance() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        let service = WorkspaceAppPackageService()
        _ = try service.exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template",
            version: "2.0.0"
        )

        let app = WorkspaceApp(
            workspaceID: UUID(),
            logicalID: "local-grocery",
            name: "Local Grocery",
            manifestRelativePath: ".astra/apps/local-grocery/manifest.json",
            appDirectoryRelativePath: ".astra/apps/local-grocery",
            manifestDigest: "local"
        )

        let check = service.checkPackageUpdate(for: app, candidatePackageURL: packageURL)

        #expect(check.status == .notPackageBacked)
        #expect(check.installedPackageID == nil)
        #expect(check.candidatePackageID == "grocery-template")
        #expect(!check.isUpdateAvailable)
        #expect(!check.requiresReview)
    }

    @MainActor
    @Test("package exporter writes workspace-local portable exports without overwriting")
    func packageExporterWritesWorkspaceLocalPortableExportsWithoutOverwriting() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspace = Workspace(name: "Package Export", primaryPath: root.path)
        container.mainContext.insert(workspace)
        let created = try WorkspaceAppService().createApp(
            manifest: Self.groceryManifest(),
            in: workspace,
            modelContext: container.mainContext,
            status: .published
        )
        let exporter = WorkspaceAppPackageExporter()

        let first = try exporter.exportTemplatePackage(
            app: created.app,
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = try exporter.exportTemplatePackage(
            app: created.app,
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 1_800_000_001)
        )

        #expect(first.packageURL.deletingLastPathComponent().path == WorkspaceFileLayout.appPackageExportRoot(workspacePath: workspace.primaryPath))
        #expect(first.packageURL.lastPathComponent == "grocery-tracker.astra-app")
        #expect(second.packageURL.lastPathComponent == "grocery-tracker-2.astra-app")
        #expect(first.validationReport.canInstall)
        #expect(FileManager.default.fileExists(atPath: first.packageURL.appendingPathComponent("package.json").path))
        #expect(FileManager.default.fileExists(atPath: first.packageURL.appendingPathComponent("checksums.json").path))
        #expect(!FileManager.default.fileExists(atPath: first.packageURL.appendingPathComponent("storage/data/full").path))
    }

    @Test("package library discovers shared folder app bundles with validation state")
    func packageLibraryDiscoversSharedFolderAppBundlesWithValidationState() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let validURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        let brokenURL = root.appendingPathComponent("broken.astra-app", isDirectory: true)
        let ignoredURL = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignoredURL, withIntermediateDirectories: true)
        try Data("not a package".utf8).write(to: ignoredURL.appendingPathComponent("README.md"))
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: validURL,
            packageID: "grocery-template",
            version: "1.2.3"
        )

        let entries = WorkspaceAppPackageLibraryService().discoverPackages(in: root)

        #expect(entries.map { $0.packageURL.lastPathComponent } == ["broken.astra-app", "grocery.astra-app"])
        let broken = try #require(entries.first { $0.packageURL.lastPathComponent == brokenURL.lastPathComponent })
        #expect(!broken.canInstall)
        #expect(broken.installState == .blocked)
        #expect(broken.packageID == nil)
        #expect(broken.blockerMessages.contains { $0.contains("package.json") })

        let valid = try #require(entries.first { $0.packageURL.lastPathComponent == validURL.lastPathComponent })
        #expect(valid.canInstall)
        #expect(valid.packageID == "grocery-template")
        #expect(valid.appName == "Grocery Tracker")
        #expect(valid.version == "1.2.3")
        #expect(valid.installState == .needsPermissionReview)
        #expect(valid.blockerMessages.isEmpty)
    }

    @Test("package library also discovers unpacked directory packages")
    func packageLibraryAlsoDiscoversUnpackedDirectoryPackages() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Grocery Template", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template"
        )

        let entries = WorkspaceAppPackageLibraryService().discoverPackages(in: root)

        #expect(entries.map(\.packageID) == ["grocery-template"])
        #expect(entries[0].packageURL.lastPathComponent == packageURL.lastPathComponent)
        #expect(entries[0].canInstall)
    }

    static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func groceryDatabase(in root: URL) throws -> URL {
        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        try service.applySchema(try #require(Self.groceryManifest().storage), databaseURL: databaseURL)
        try service.insertRecord(
            [
                "id": .text("item-1"),
                "name": .text("Apples"),
                "category": .text("Produce"),
                "quantity": .integer(6)
            ],
            into: "items",
            databaseURL: databaseURL
        )
        try service.insertRecord(
            [
                "id": .text("item-2"),
                "name": .text("Rice"),
                "category": .text("Pantry"),
                "quantity": .integer(1)
            ],
            into: "items",
            databaseURL: databaseURL
        )
        return databaseURL
    }

    static func updatePackageTrustMetadata(
        at packageURL: URL,
        trustMetadata: WorkspaceAppPackageTrustMetadata
    ) throws {
        let packageJSONURL = packageURL.appendingPathComponent("package.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var package = try decoder.decode(
            WorkspaceAppPackageManifest.self,
            from: Data(contentsOf: packageJSONURL)
        )
        package.trustMetadata = trustMetadata

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(package).write(to: packageJSONURL, options: [.atomic])
        try rewriteChecksums(at: packageURL)
    }

    static func rewriteChecksums(at packageURL: URL) throws {
        let checksums = try portableFilePaths(in: packageURL)
            .filter { $0 != "checksums.json" }
            .map { path in
                let data = try Data(contentsOf: packageURL.appendingPathComponent(path))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return WorkspaceAppPackageChecksum(path: path, sha256: digest)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checksums)
            .write(to: packageURL.appendingPathComponent("checksums.json"), options: [.atomic])
    }

    static func portableFilePaths(in packageURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            let basePath = packageURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let filePath = url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard filePath.hasPrefix("\(basePath)/") else { return nil }
            return String(filePath.dropFirst(basePath.count + 1))
        }
        .sorted()
    }

    static func groceryManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery-tracker",
                name: "Grocery Tracker",
                icon: "cart",
                description: "Track grocery inventory and shopping lists.",
                tags: ["local", "grocery"],
                archetypes: ["localDatabase"]
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "localRecords",
                    contract: "appStorage.records",
                    operations: ["insertRecord", "queryRecords"]
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "category", type: "text"),
                    WorkspaceAppStorageColumn(name: "quantity", type: "integer")
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "items",
                    requirementRef: "localRecords",
                    operation: "queryRecords",
                    sourceRef: "items"
                )
            ],
            views: [
                WorkspaceAppViewSpec(id: "items", type: "table", title: "Items")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "addItem",
                    type: "appStorage.insert",
                    label: "Add Item",
                    requirementRef: "localRecords",
                    operation: "insertRecord"
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                defaultMode: .draftOnly
            )
        )
    }
}
