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

    @Test("template package validation treats missing data exports manifest as empty")
    func templatePackageValidationTreatsMissingDataExportsManifestAsEmpty() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-template.astra-app", isDirectory: true)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL
        )

        #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("storage/data/exports.json").path))

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(report.canInstall)
        #expect(!report.blockers.contains { $0.path == "/storage/data/exports.json" })
    }

    @Test("data package validation requires an exports manifest for storage tables")
    func dataPackageValidationRequiresExportsManifestForStorageTables() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-seed-missing-exports.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-seed-missing-exports",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        try FileManager.default.removeItem(at: packageURL.appendingPathComponent("storage/data/exports.json"))
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/exports.json"
                && $0.message.contains("file is missing")
        })
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

    @Test("package validation rejects symlinked data exports outside the package")
    func packageValidationRejectsSymlinkedDataExportsOutsidePackage() throws {
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
        let outsideURL = root.appendingPathComponent("outside-items.jsonl")
        try FileManager.default.copyItem(at: dataURL, to: outsideURL)
        try FileManager.default.removeItem(at: dataURL)
        try FileManager.default.createSymbolicLink(atPath: dataURL.path, withDestinationPath: outsideURL.path)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/seed/items.jsonl"
                && $0.message.contains("inside the package")
        })
    }

    @Test("package validation rejects symlinked data export parent directories")
    func packageValidationRejectsSymlinkedDataExportParentDirectories() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-seed-parent.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-seed-parent",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        let seedDirectory = packageURL.appendingPathComponent("storage/data/seed", isDirectory: true)
        let outsideSeedDirectory = root.appendingPathComponent("outside-seed", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideSeedDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: seedDirectory.appendingPathComponent("items.jsonl"),
            to: outsideSeedDirectory.appendingPathComponent("items.jsonl")
        )
        try FileManager.default.removeItem(at: seedDirectory)
        try FileManager.default.createSymbolicLink(
            atPath: seedDirectory.path,
            withDestinationPath: outsideSeedDirectory.path
        )

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/seed/items.jsonl"
                && $0.message.contains("inside the package")
        })
    }

    @Test("package validation rejects NUL bytes in data export paths before opening files")
    func packageValidationRejectsNULBytesInDataExportPathsBeforeOpeningFiles() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-nul-export.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-nul-export",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        let truncatedTargetURL = packageURL.appendingPathComponent("storage/data/seed/items")
        try FileManager.default.copyItem(
            at: packageURL.appendingPathComponent("storage/data/seed/items.jsonl"),
            to: truncatedTargetURL
        )
        try Self.writeDataExports(
            [
                WorkspaceAppPackageDataExport(
                    table: "items",
                    policy: .seed,
                    path: "storage/data/seed/items\u{0}.jsonl",
                    rowCount: 2
                )
            ],
            to: packageURL
        )

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/exports.json"
                && $0.message.contains("path")
                && $0.message.contains("storage data folder")
        })
    }

    @Test("package validation reports invalid UTF-8 data exports as encoding errors")
    func packageValidationReportsInvalidUTF8DataExportsAsEncodingErrors() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-invalid-utf8.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-invalid-utf8",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        let dataURL = packageURL.appendingPathComponent("storage/data/seed/items.jsonl")
        try Data([0xff, 0xfe, 0xfd]).write(to: dataURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/seed/items.jsonl"
                && $0.message.contains("UTF-8")
        })
        #expect(!report.blockers.contains {
            $0.path == "/storage/data/seed/items.jsonl"
                && $0.message.contains("regular file inside the package")
        })
    }

    @Test("package validation reads multi-chunk data exports through descriptor buffer")
    func packageValidationReadsMultiChunkDataExportsThroughDescriptorBuffer() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-large-export.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-large-export",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        let dataPath = "storage/data/seed/items.jsonl"
        let row: [String: WorkspaceAppStorageValue] = [
            "id": .text("item-large"),
            "name": .text(String(repeating: "A", count: 70_000)),
            "category": .text("Bulk"),
            "quantity": .integer(1)
        ]
        let rowData = try JSONEncoder().encode(row)
        try rowData.write(to: packageURL.appendingPathComponent(dataPath), options: [.atomic])
        try Self.writeDataExports(
            [
                WorkspaceAppPackageDataExport(
                    table: "items",
                    policy: .seed,
                    path: dataPath,
                    rowCount: 1
                )
            ],
            to: packageURL
        )

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(report.canInstall)
        #expect(!report.blockers.contains {
            $0.path == "/storage/data/exports.json"
                && $0.message.contains("row count")
        })
    }

    @Test("package validation reports malformed JSON Lines as format errors")
    func packageValidationReportsMalformedJSONLinesAsFormatErrors() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-malformed-jsonl.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-malformed-jsonl",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        let dataURL = packageURL.appendingPathComponent("storage/data/seed/items.jsonl")
        try Data(#"{"id":"item-1","name":"Apples""#.utf8).write(to: dataURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/seed/items.jsonl"
                && $0.message.contains("valid JSON Lines")
        })
        #expect(!report.blockers.contains {
            $0.path == "/storage/data/seed/items.jsonl"
                && $0.message.contains("regular file inside the package")
        })
    }

    @Test("package validation reports invalid UTF-8 package JSON separately")
    func packageValidationReportsInvalidUTF8PackageJSONSeparately() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-invalid-package-json.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-invalid-package-json"
        )
        try Data([0xff, 0xfe, 0xfd]).write(to: packageURL.appendingPathComponent("package.json"), options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/package.json"
                && $0.message.contains("valid UTF-8")
        })
    }

    @Test("package validation distinguishes invalid exports manifest from missing exports manifest")
    func packageValidationDistinguishesInvalidExportsManifestFromMissingExportsManifest() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-invalid-exports.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-invalid-exports",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        let exportsURL = packageURL.appendingPathComponent("storage/data/exports.json")
        let outsideURL = root.appendingPathComponent("outside-exports.json")
        try Data("[]".utf8).write(to: outsideURL)
        try FileManager.default.removeItem(at: exportsURL)
        try FileManager.default.createSymbolicLink(atPath: exportsURL.path, withDestinationPath: outsideURL.path)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/exports.json"
                && $0.message.contains("regular file inside the package")
        })
    }

    @Test("package validation rejects dangling exports manifests")
    func packageValidationRejectsDanglingExportsManifests() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("grocery-dangling-exports.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-dangling-exports",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )
        let exportsURL = packageURL.appendingPathComponent("storage/data/exports.json")
        try FileManager.default.removeItem(at: exportsURL)
        try FileManager.default.createSymbolicLink(
            atPath: exportsURL.path,
            withDestinationPath: root.appendingPathComponent("missing-exports.json").path
        )
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/exports.json"
                && $0.message.contains("regular file inside the package")
        })
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

    @Test("package validation blocks oversized JSONL exports before import")
    func packageValidationBlocksOversizedJSONLExportsBeforeImport() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("oversized-data.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "oversized-data",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )

        let dataURL = packageURL.appendingPathComponent("storage/data/seed/items.jsonl")
        let oversizedRow = #"{"id":{"text":"\#(String(repeating: "item", count: 80_000))"}}"#
        try Data(oversizedRow.utf8).write(to: dataURL, options: [.atomic])
        let exports = [
            WorkspaceAppPackageDataExport(
                table: "items",
                policy: .seed,
                path: "storage/data/seed/items.jsonl",
                rowCount: 1
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exports)
            .write(to: packageURL.appendingPathComponent("storage/data/exports.json"), options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/seed/items.jsonl"
                && $0.message.lowercased().contains("package resource limit")
        })
    }

    @Test("package validation rejects malformed JSONL exports before import")
    func packageValidationRejectsMalformedJSONLExportsBeforeImport() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("malformed-data.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "malformed-data",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )

        let dataPath = "storage/data/seed/items.jsonl"
        let dataURL = packageURL.appendingPathComponent(dataPath)
        let malformedJSONL = """
        {"id":"item-1","name":"Apples"}
        not-json

        """
        try Data(malformedJSONL.utf8)
            .write(to: dataURL, options: [.atomic])
        let exports = [
            WorkspaceAppPackageDataExport(
                table: "items",
                policy: .seed,
                path: dataPath,
                rowCount: 2
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exports)
            .write(to: packageURL.appendingPathComponent("storage/data/exports.json"), options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/\(dataPath)"
        })
    }

    @Test("package validation streams large JSONL exports outside scanned text cap")
    func packageValidationStreamsLargeJSONLExportsOutsideScannedTextCap() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("large-data.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "large-data",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )

        let dataPath = "storage/data/seed/items.jsonl"
        let rows = (0..<10).map { index in
            #"{"id":"item-\#(index)","name":"\#(String(repeating: "a", count: 220_000))"}"#
        }
        try Data(rows.joined(separator: "\n").utf8)
            .write(to: packageURL.appendingPathComponent(dataPath), options: [.atomic])
        let exports = [
            WorkspaceAppPackageDataExport(
                table: "items",
                policy: .seed,
                path: dataPath,
                rowCount: rows.count
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exports)
            .write(to: packageURL.appendingPathComponent("storage/data/exports.json"), options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(report.canInstall)
    }

    @Test("package validation scans JSONL export keys for credentials")
    func packageValidationScansJSONLExportKeysForCredentials() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("credential-key-data.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "credential-key-data",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )

        let dataPath = "storage/data/seed/items.jsonl"
        try Data(#"{"api_key":"abc123"}"#.utf8)
            .write(to: packageURL.appendingPathComponent(dataPath), options: [.atomic])
        let exports = [
            WorkspaceAppPackageDataExport(
                table: "items",
                policy: .seed,
                path: dataPath,
                rowCount: 1
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exports)
            .write(to: packageURL.appendingPathComponent("storage/data/exports.json"), options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/\(dataPath)" && $0.message.contains("credential")
        })
    }

    @Test("package validation reports each forbidden JSONL export issue once per file")
    func packageValidationDeduplicatesForbiddenJSONLExportIssues() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("duplicate-unsafe-data.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "duplicate-unsafe-data",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )

        let dataPath = "storage/data/seed/items.jsonl"
        let rows = [
            #"{"api_key":"secret","path":"/Users/alvaro/private.csv"}"#,
            #"{"token":"secret","home":"/Users/alvaro/other.csv"}"#
        ]
        try Data(rows.joined(separator: "\n").utf8)
            .write(to: packageURL.appendingPathComponent(dataPath), options: [.atomic])
        let exports = [
            WorkspaceAppPackageDataExport(
                table: "items",
                policy: .seed,
                path: dataPath,
                rowCount: rows.count
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exports)
            .write(to: packageURL.appendingPathComponent("storage/data/exports.json"), options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.filter {
            $0.path == "/\(dataPath)" && $0.message.contains("credential")
        }.count == 1)
        #expect(report.blockers.filter {
            $0.path == "/\(dataPath)" && $0.message.contains("absolute local path")
        }.count == 1)
    }

    @Test("package validation scans portable JSONL assets as text")
    func packageValidationScansPortableJSONLAssetsAsText() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("jsonl-fixture.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let fixtureURL = packageURL.appendingPathComponent("docs/fixtures/browser-events.jsonl")
        try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(##"{"event":{"name":"loaded","metadata":{"selector":"#submit"}}}"##.utf8)
            .write(to: fixtureURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(report.canInstall)
        #expect(!report.blockers.contains { $0.path == "/docs/fixtures/browser-events.jsonl" })
    }

    @Test("package validation applies scanned-text cap to portable JSONL assets")
    func packageValidationAppliesScannedTextCapToPortableJSONLAssets() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("large-jsonl-fixture.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let fixturePath = "docs/fixtures/browser-events.jsonl"
        let fixtureURL = packageURL.appendingPathComponent(fixturePath)
        try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            ((0..<6_000)
                .map { #"{"event":"loaded-\#($0)"}"# }
                + [#"{"event":"loaded","token":"should-not-be-scanned-after-cap"}"#])
                .joined(separator: "\n")
                .utf8
        )
        .write(to: fixtureURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        var service = WorkspaceAppPackageService()
        service.resourceReader.budget = WorkspaceAppPackageResourceBudget(
            maxPackageBytes: 32 * 1_024 * 1_024,
            maxFileBytes: 8 * 1_024 * 1_024,
            maxScannedTextFileBytes: 100_000,
            maxJSONLRows: 10_000,
            maxJSONLLineBytes: 256 * 1_024
        )

        let report = service.validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/\(fixturePath)"
                && $0.message.lowercased().contains("package resource limit")
        })
        #expect(!report.blockers.contains {
            $0.path == "/\(fixturePath)"
                && $0.message.lowercased().contains("credential material")
        })
    }

    @Test("package validation rejects malformed data export descriptors")
    func packageValidationRejectsMalformedDataExportDescriptors() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("malformed-exports.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let exportsURL = packageURL.appendingPathComponent("storage/data/exports.json")
        try FileManager.default.createDirectory(at: exportsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"path":"storage/data/sample/items.jsonl"}"#.utf8).write(to: exportsURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/exports.json"
                && $0.message.contains("Could not decode data exports")
        })
    }

    @Test("package validation rejects exports for unknown manifest tables")
    func packageValidationRejectsExportsForUnknownManifestTables() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("unknown-table-data.astra-app", isDirectory: true)
        let databaseURL = try Self.groceryDatabase(in: root)

        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "unknown-table-data",
            mode: .templatePlusSeedData,
            appStorageDatabaseURL: databaseURL
        )

        let dataPath = "storage/data/seed/shadow.jsonl"
        let dataURL = packageURL.appendingPathComponent(dataPath)
        let row = #"{"id":"shadow-1","token":"\#(String(repeating: "unimported", count: 4_000))"}"#
        try Data(row.utf8)
            .write(to: dataURL, options: [.atomic])
        let exports = [
            WorkspaceAppPackageDataExport(
                table: "shadow",
                policy: .seed,
                path: dataPath,
                rowCount: 1
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exports)
            .write(to: packageURL.appendingPathComponent("storage/data/exports.json"), options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        var service = WorkspaceAppPackageService()
        service.resourceReader.budget = WorkspaceAppPackageResourceBudget(
            maxPackageBytes: 32 * 1_024 * 1_024,
            maxFileBytes: 8 * 1_024 * 1_024,
            maxScannedTextFileBytes: 20 * 1_024,
            maxJSONLRows: 10_000,
            maxJSONLLineBytes: 256 * 1_024
        )

        let report = service.validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/storage/data/exports.json"
                && $0.message.contains("unknown storage table 'shadow'")
        })
        #expect(report.blockers.contains {
            $0.path == "/\(dataPath)"
                && $0.message.lowercased().contains("package resource limit")
        })
    }

    @Test("package validation rejects checksummed symlink resources before hashing")
    func packageValidationRejectsChecksummedSymlinkResourcesBeforeHashing() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("symlinked-resource.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "symlinked-resource"
        )

        let targetURL = root.appendingPathComponent("outside.md")
        try Data("external package target".utf8).write(to: targetURL)
        let linkPath = "docs/link.md"
        let linkURL = packageURL.appendingPathComponent(linkPath)
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        var checksums = try JSONDecoder().decode(
            [WorkspaceAppPackageChecksum].self,
            from: Data(contentsOf: packageURL.appendingPathComponent("checksums.json"))
        )
        checksums.append(WorkspaceAppPackageChecksum(path: linkPath, sha256: String(repeating: "0", count: 64)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checksums)
            .write(to: packageURL.appendingPathComponent("checksums.json"), options: [.atomic])

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/\(linkPath)"
                && $0.message.contains("regular files")
        })
    }

    @Test("package validation rejects unchecksummed non-regular package entries")
    func packageValidationRejectsUnchecksummedNonRegularPackageEntries() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("linked-resource.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let linkURL = packageURL.appendingPathComponent("assets/manifest-link.json")
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: packageURL.appendingPathComponent("manifest.json")
        )

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/assets/manifest-link.json"
                && $0.message.contains("regular files")
        })
    }

    @Test("package validation rejects symlink directory package entries")
    func packageValidationRejectsSymlinkDirectoryPackageEntries() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("linked-directory.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let targetURL = root.appendingPathComponent("outside-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let linkPath = "assets/linked-directory"
        let linkURL = packageURL.appendingPathComponent(linkPath, isDirectory: true)
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/\(linkPath)"
                && $0.message.contains("regular files")
        })
    }

    @Test("package entry policy includes symlink directories for non-regular validation")
    func packageEntryPolicyIncludesSymlinkDirectoriesForNonRegularValidation() {
        #expect(!WorkspaceAppPackageEntryPolicy.includesInResourceValidation(
            isDirectory: true,
            isSymbolicLink: false
        ))
        #expect(WorkspaceAppPackageEntryPolicy.includesInResourceValidation(
            isDirectory: true,
            isSymbolicLink: true
        ))
        #expect(WorkspaceAppPackageEntryPolicy.includesInResourceValidation(
            isDirectory: false,
            isSymbolicLink: false
        ))
    }

    @Test("package validation stops expensive checks after resource budget failure")
    func packageValidationStopsExpensiveChecksAfterResourceBudgetFailure() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("over-budget.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let assetURL = packageURL.appendingPathComponent("assets/fixture.json")
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"fixture":"original"}"#.utf8).write(to: assetURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)
        try Data(#"{"fixture":"changed"}"#.utf8).write(to: assetURL, options: [.atomic])

        var service = WorkspaceAppPackageService()
        service.resourceReader.budget = WorkspaceAppPackageResourceBudget(
            maxPackageBytes: 1,
            maxFileBytes: 8 * 1_024 * 1_024,
            maxScannedTextFileBytes: 2 * 1_024 * 1_024,
            maxJSONLRows: 10_000,
            maxJSONLLineBytes: 256 * 1_024
        )

        let report = service.validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/" && $0.message.lowercased().contains("package resource limit")
        })
        #expect(!report.blockers.contains {
            $0.path.hasPrefix("/checksums.json/")
        })
    }

    @Test("package validation stops expensive checks after file resource budget failure")
    func packageValidationStopsExpensiveChecksAfterFileResourceBudgetFailure() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("over-file-budget.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        let assetURL = packageURL.appendingPathComponent("assets/fixture.json")
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"fixture":"\#(String(repeating: "original", count: 20_000))"}"#.utf8).write(to: assetURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)
        try Data(#"{"fixture":"\#(String(repeating: "changed", count: 20_000))"}"#.utf8).write(to: assetURL, options: [.atomic])

        var service = WorkspaceAppPackageService()
        service.resourceReader.budget = WorkspaceAppPackageResourceBudget(
            maxPackageBytes: 32 * 1_024 * 1_024,
            maxFileBytes: 64 * 1_024,
            maxScannedTextFileBytes: 2 * 1_024 * 1_024,
            maxJSONLRows: 10_000,
            maxJSONLLineBytes: 256 * 1_024
        )

        let report = service.validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/assets/fixture.json"
                && $0.message.lowercased().contains("package resource limit")
        })
        #expect(!report.blockers.contains {
            $0.path.hasPrefix("/checksums.json/")
        })
    }

    @Test("package validation counts hidden package entries toward resource budgets")
    func packageValidationCountsHiddenPackageEntriesTowardResourceBudgets() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("hidden-payload.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(manifest: Self.groceryManifest(), to: packageURL)

        try Data(String(repeating: "hidden", count: 20_000).utf8)
            .write(to: packageURL.appendingPathComponent(".payload"), options: [.atomic])

        var service = WorkspaceAppPackageService()
        service.resourceReader.budget = WorkspaceAppPackageResourceBudget(
            maxPackageBytes: 32 * 1_024 * 1_024,
            maxFileBytes: 64 * 1_024,
            maxScannedTextFileBytes: 2 * 1_024 * 1_024,
            maxJSONLRows: 10_000,
            maxJSONLLineBytes: 256 * 1_024
        )

        let report = service.validatePackage(at: packageURL)

        #expect(!report.canInstall)
        #expect(report.blockers.contains {
            $0.path == "/.payload"
                && $0.message.lowercased().contains("package resource limit")
        })
    }

    @Test("package resource budgets treat byte total overflow as over budget")
    func packageResourceBudgetsTreatByteTotalOverflowAsOverBudget() throws {
        var reader = WorkspaceAppPackageResourceReader()
        reader.budget = WorkspaceAppPackageResourceBudget(
            maxPackageBytes: Int.max,
            maxFileBytes: Int.max,
            maxScannedTextFileBytes: Int.max,
            maxJSONLRows: 10_000,
            maxJSONLLineBytes: 256 * 1_024
        )
        reader.regularFileSize = { _, relativePath in
            relativePath == "/first.bin" ? Int.max : 1
        }

        #expect(throws: WorkspaceAppPackageResourceError.packageTooLarge(actual: Int.max, maximum: Int.max)) {
            try reader.validatePackageFiles(
                packageURL: URL(fileURLWithPath: "/tmp/nonexistent-package"),
                paths: ["first.bin", "second.bin"],
                isScannedTextPath: { _ in false }
            )
        }
    }

    @Test("package library discovery blocks oversized portable text")
    func packageLibraryDiscoveryBlocksOversizedPortableText() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("oversized-text.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "oversized-text"
        )

        let readmeURL = packageURL.appendingPathComponent("docs/README.md")
        try Data(String(repeating: "portable package note\n", count: 120_000).utf8)
            .write(to: readmeURL, options: [.atomic])
        try Self.rewriteChecksums(at: packageURL)

        let entry = try #require(WorkspaceAppPackageLibraryService()
            .discoverPackages(in: root)
            .first { $0.packageURL.lastPathComponent == packageURL.lastPathComponent })
        let report = WorkspaceAppPackageService().validatePackage(at: packageURL)

        #expect(!entry.canInstall)
        #expect(entry.blockerMessages.contains { $0.lowercased().contains("package resource limit") })
        #expect(report.blockers.contains {
            $0.path == "/docs/README.md"
                && $0.message.lowercased().contains("package resource limit")
        })
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
    @Test("package import rejects app directory symlink escapes")
    func packageImportRejectsAppDirectorySymlinkEscapes() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let packageURL = root.appendingPathComponent("grocery.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.groceryManifest(),
            to: packageURL,
            packageID: "grocery-template"
        )

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let appRoot = workspaceURL.appendingPathComponent(".astra/apps", isDirectory: true)
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: appRoot.appendingPathComponent("grocery-tracker", isDirectory: true),
            withDestinationURL: outside
        )
        let workspace = Workspace(name: "Package Import", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        #expect(throws: WorkspaceAppServiceError.self) {
            _ = try WorkspaceAppPackageService().importPackage(
                at: packageURL,
                into: workspace,
                modelContext: container.mainContext
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("data/app.sqlite").path))
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
    @Test("package import reports invalid package when seed file disappears after validation")
    func packageImportReportsInvalidPackageWhenSeedFileDisappearsAfterValidation() throws {
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
        let service = WorkspaceAppPackageService()
        let report = service.validatePackage(at: packageURL)
        #expect(report.canInstall)
        try FileManager.default.removeItem(at: packageURL.appendingPathComponent("storage/data/seed/items.jsonl"))

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Package Import", primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)

        do {
            _ = try service.importPackage(
                at: packageURL,
                validatedBy: report,
                into: workspace,
                modelContext: container.mainContext
            )
            Issue.record("Expected late package-file resolution failure to report an invalid package.")
        } catch let error as WorkspaceAppPackageError {
            guard case .invalidPackage(let report) = error else {
                Issue.record("Expected invalidPackage, got \(error).")
                return
            }
            #expect(!report.canInstall)
            #expect(report.blockers.contains { issue in
                issue.path == "/storage/data/exports.json"
                    && issue.message == "Data export references a missing file."
            })
        }
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

    @MainActor
    @Test("package exporter reads canonical manifest when stored relative path is stale")
    func packageExporterReadsCanonicalManifestWhenStoredRelativePathIsStale() throws {
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
        created.app.manifestRelativePath = ".astra/apps/stale-grocery/manifest.json"
        created.app.appDirectoryRelativePath = ".astra/apps/stale-grocery"

        let export = try WorkspaceAppPackageExporter().exportTemplatePackage(
            app: created.app,
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(export.validationReport.canInstall)
        #expect(export.validationReport.package?.appID == created.app.logicalID)
    }

    @MainActor
    @Test("package exporter rejects export root symlink escapes")
    func packageExporterRejectsExportRootSymlinkEscapes() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
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
        let exportRoot = URL(fileURLWithPath: WorkspaceFileLayout.appPackageExportRoot(workspacePath: workspace.primaryPath), isDirectory: true)
        try FileManager.default.createSymbolicLink(at: exportRoot, withDestinationURL: outside)

        #expect(throws: WorkspaceAppPackageExportError.unsafeExportPath(exportRoot.path)) {
            _ = try WorkspaceAppPackageExporter().exportTemplatePackage(
                app: created.app,
                workspace: workspace,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("grocery-tracker.astra-app").path))
    }

    @MainActor
    @Test("package exporter rejects symlinked app roots before writing exports")
    func packageExporterRejectsSymlinkedAppRootsBeforeWritingExports() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
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
        let appRoot = URL(fileURLWithPath: WorkspaceFileLayout.appRoot(for: workspace.primaryPath), isDirectory: true)
        let movedRoot = outside.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.moveItem(at: appRoot, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: appRoot, withDestinationURL: movedRoot)

        #expect(throws: WorkspaceAppPackageExportError.unsafeExportPath(WorkspaceFileLayout.appPackageExportRoot(workspacePath: workspace.primaryPath))) {
            _ = try WorkspaceAppPackageExporter().exportTemplatePackage(
                app: created.app,
                workspace: workspace,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("exports/grocery-tracker.astra-app").path))
    }

    @MainActor
    @Test("package exporter rejects symlinked app storage before exporting rows")
    func packageExporterRejectsSymlinkedAppStorageBeforeExportingRows() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
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
        let appDirectory = try #require(WorkspaceFileLayout.appDirectoryURL(
            workspacePath: workspace.primaryPath,
            appID: created.app.logicalID
        ))
        let dataDirectory = appDirectory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.removeItem(at: dataDirectory)
        _ = try Self.groceryDatabase(in: outside)
        try FileManager.default.createSymbolicLink(at: dataDirectory, withDestinationURL: outside)
        let packageURL = appDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("exports/grocery-tracker.astra-app", isDirectory: true)

        #expect(throws: WorkspaceAppPackageExportError.unsafeExportPath(dataDirectory.appendingPathComponent("app.sqlite").path)) {
            _ = try WorkspaceAppPackageExporter().exportTemplatePackage(
                app: created.app,
                workspace: workspace,
                mode: .fullAppExport,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("storage/data/full/items.jsonl").path))
    }

    @MainActor
    @Test("package exporter rejects export directories that alias another app")
    func packageExporterRejectsExportDirectoriesThatAliasAnotherApp() throws {
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
        let appRoot = URL(fileURLWithPath: WorkspaceFileLayout.appRoot(for: workspace.primaryPath), isDirectory: true)
        let exportRoot = appRoot.appendingPathComponent("exports", isDirectory: true)
        let existingAppDirectory = appRoot.appendingPathComponent("grocery-tracker", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: exportRoot, withDestinationURL: existingAppDirectory)

        #expect(throws: WorkspaceAppPackageExportError.unsafeExportPath(exportRoot.path)) {
            _ = try WorkspaceAppPackageExporter().exportTemplatePackage(
                app: created.app,
                workspace: workspace,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: existingAppDirectory.appendingPathComponent("grocery-tracker.astra-app").path))
    }

    @MainActor
    @Test("package exporter sanitizes package directory names from persisted app IDs")
    func packageExporterSanitizesPackageDirectoryNamesFromPersistedAppIDs() throws {
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
        created.app.logicalID = "../../escape"

        let export = try WorkspaceAppPackageExporter().exportTemplatePackage(
            app: created.app,
            workspace: workspace,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let exportRoot = try #require(WorkspaceFileLayout.appPackageExportRootURL(workspacePath: workspace.primaryPath))
        #expect(export.packageURL.deletingLastPathComponent().path == exportRoot.path)
        #expect(export.packageURL.lastPathComponent == "escape.astra-app")
        #expect(FileManager.default.fileExists(atPath: export.packageURL.appendingPathComponent("package.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".astra/escape.astra-app").path))
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

    static func writeDataExports(
        _ exports: [WorkspaceAppPackageDataExport],
        to packageURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exports)
            .write(to: packageURL.appendingPathComponent("storage/data/exports.json"), options: [.atomic])
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
