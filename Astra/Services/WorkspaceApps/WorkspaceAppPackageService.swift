import CryptoKit
import Darwin
import Foundation
import SwiftData

enum WorkspaceAppPackageExportMode: String, Codable, Sendable, Equatable, CaseIterable {
    case templateOnly
    case templatePlusSampleData
    case templatePlusSeedData
    case fullAppExport
}

enum WorkspaceAppPackageInstallState: String, Codable, Sendable, Equatable, CaseIterable {
    case decoded
    case validated
    case needsDependencyMapping
    case needsPermissionReview
    case readyToInstall
    case installedDisabled
    case installedReady
    case blocked
}

struct WorkspaceAppPackageManifest: Codable, Sendable, Equatable {
    var packageID: String
    var appID: String
    var appName: String
    var version: String
    var minimumASTRAVersion: String
    var sourceManifestDigest: String
    var exportMode: WorkspaceAppPackageExportMode
    var createdAt: Date
    var author: String?
    var trustMetadata: WorkspaceAppPackageTrustMetadata?
    var requiredContracts: [WorkspaceAppPackageContractRequirement]
    var implementationDescriptors: [WorkspaceAppContractImplementation]

    enum CodingKeys: String, CodingKey {
        case packageID
        case appID
        case appName
        case version
        case minimumASTRAVersion
        case sourceManifestDigest
        case exportMode
        case createdAt
        case author
        case trustMetadata
        case requiredContracts
        case implementationDescriptors
    }

    init(
        packageID: String,
        appID: String,
        appName: String,
        version: String,
        minimumASTRAVersion: String,
        sourceManifestDigest: String,
        exportMode: WorkspaceAppPackageExportMode,
        createdAt: Date,
        author: String?,
        trustMetadata: WorkspaceAppPackageTrustMetadata? = nil,
        requiredContracts: [WorkspaceAppPackageContractRequirement],
        implementationDescriptors: [WorkspaceAppContractImplementation] = []
    ) {
        self.packageID = packageID
        self.appID = appID
        self.appName = appName
        self.version = version
        self.minimumASTRAVersion = minimumASTRAVersion
        self.sourceManifestDigest = sourceManifestDigest
        self.exportMode = exportMode
        self.createdAt = createdAt
        self.author = author
        self.trustMetadata = trustMetadata
        self.requiredContracts = requiredContracts
        self.implementationDescriptors = implementationDescriptors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageID = try container.decode(String.self, forKey: .packageID)
        appID = try container.decode(String.self, forKey: .appID)
        appName = try container.decode(String.self, forKey: .appName)
        version = try container.decode(String.self, forKey: .version)
        minimumASTRAVersion = try container.decode(String.self, forKey: .minimumASTRAVersion)
        sourceManifestDigest = try container.decode(String.self, forKey: .sourceManifestDigest)
        exportMode = try container.decode(WorkspaceAppPackageExportMode.self, forKey: .exportMode)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        trustMetadata = try container.decodeIfPresent(WorkspaceAppPackageTrustMetadata.self, forKey: .trustMetadata)
        requiredContracts = try container.decodeIfPresent([WorkspaceAppPackageContractRequirement].self, forKey: .requiredContracts) ?? []
        implementationDescriptors = try container.decodeIfPresent([WorkspaceAppContractImplementation].self, forKey: .implementationDescriptors) ?? []
    }
}

struct WorkspaceAppPackageTrustMetadata: Codable, Sendable, Equatable {
    var signerIdentity: String?
    var signedAt: Date?
    var packageDigest: String?
    var trustSource: String?
    var revocationStatus: String?
    var signatureValidationResult: String?
}

struct WorkspaceAppPackageContractRequirement: Codable, Sendable, Equatable {
    var id: String
    var contract: String
    var minVersion: String?
    var operations: [String]
    var providerHint: String?
    var providerRequired: String?
    var optional: Bool
}

struct WorkspaceAppPackageChecksum: Codable, Sendable, Equatable {
    var path: String
    var sha256: String
}

struct WorkspaceAppPackageDataExport: Codable, Sendable, Equatable {
    var table: String
    var policy: WorkspaceAppPackageDataExportPolicy
    var path: String
    var rowCount: Int
}

enum WorkspaceAppPackageDataExportPolicy: String, Codable, Sendable, Equatable, CaseIterable {
    case sample
    case seed
    case full
}

struct WorkspaceAppPackageValidationReport: Sendable, Equatable {
    struct Issue: Sendable, Equatable {
        enum Severity: String, Sendable, Equatable {
            case blocker
            case warning
        }

        var severity: Severity
        var path: String
        var message: String
    }

    var package: WorkspaceAppPackageManifest?
    var manifest: WorkspaceAppManifest?
    var issues: [Issue]
    var installState: WorkspaceAppPackageInstallState

    var blockers: [Issue] {
        issues.filter { $0.severity == .blocker }
    }

    var warnings: [Issue] {
        issues.filter { $0.severity == .warning }
    }

    var canInstall: Bool {
        blockers.isEmpty && package != nil && manifest != nil
    }
}

enum WorkspaceAppPackageUpdateStatus: String, Sendable, Equatable {
    case notPackageBacked
    case invalidCandidate
    case differentPackage
    case sameVersionSameDigest
    case sameVersionDifferentDigest
    case updateAvailable
    case installedVersionNewer
}

struct WorkspaceAppPackageUpdateCheck: Sendable, Equatable {
    var status: WorkspaceAppPackageUpdateStatus
    var installedPackageID: String?
    var installedVersion: String?
    var installedDigest: String?
    var candidatePackageID: String?
    var candidateVersion: String?
    var candidateDigest: String?
    var validationReport: WorkspaceAppPackageValidationReport

    var isUpdateAvailable: Bool {
        status == .updateAvailable
    }

    var requiresReview: Bool {
        status == .updateAvailable || status == .sameVersionDifferentDigest
    }
}

enum WorkspaceAppPackageError: LocalizedError, Equatable {
    case invalidPackage(WorkspaceAppPackageValidationReport)
    case invalidManifest([WorkspaceAppManifestValidationReport.Issue])
    case packageAlreadyExists(String)
    case missingStorageDatabase(WorkspaceAppPackageExportMode)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let report):
            let messages = report.blockers.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Workspace app package is invalid.\n\(messages)"
        case .invalidManifest(let issues):
            let messages = issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            return "Workspace app manifest is invalid.\n\(messages)"
        case .packageAlreadyExists(let path):
            return "Workspace app package already exists at \(path)."
        case .missingStorageDatabase(let mode):
            return "Workspace app package export mode \(mode.rawValue) needs an app storage database."
        }
    }
}

private enum WorkspaceAppPackageFileResolutionError: Error {
    case invalidEncoding
    case invalidPath
    case missing
}

struct WorkspaceAppPackageImportResult {
    var app: WorkspaceApp
    var report: WorkspaceAppPackageValidationReport
    var manifestURL: URL
}

struct WorkspaceAppPackageService {
    var fileManager: FileManager = .default
    var appService = WorkspaceAppService()
    var storageService = WorkspaceAppStorageService()

    func exportPackage(
        manifest: WorkspaceAppManifest,
        to packageURL: URL,
        packageID: String? = nil,
        version: String = "1.0.0",
        minimumASTRAVersion: String = "0.1.0",
        mode: WorkspaceAppPackageExportMode = .templateOnly,
        appStorageDatabaseURL: URL? = nil,
        author: String? = nil,
        createdAt: Date = Date(),
        implementationDescriptors: [WorkspaceAppContractImplementation] = []
    ) throws -> URL {
        let report = WorkspaceAppManifestValidator.validate(manifest)
        guard report.isValid else {
            throw WorkspaceAppPackageError.invalidManifest(report.blockers)
        }
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw WorkspaceAppPackageError.packageAlreadyExists(packageURL.path)
        }

        let manifestData = try WorkspaceAppService.encodeManifest(manifest)
        let package = WorkspaceAppPackageManifest(
            packageID: packageID ?? "\(manifest.app.id).astra-app",
            appID: manifest.app.id,
            appName: manifest.app.name,
            version: version,
            minimumASTRAVersion: minimumASTRAVersion,
            sourceManifestDigest: WorkspaceAppService.digest(for: manifestData),
            exportMode: mode,
            createdAt: createdAt,
            author: author,
            requiredContracts: manifest.requirements.map(Self.packageRequirement),
            implementationDescriptors: implementationDescriptors
        )

        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try writeJSON(package, to: packageURL.appendingPathComponent("package.json"))
        try manifestData.write(to: packageURL.appendingPathComponent("manifest.json"), options: [.atomic])
        if let storage = manifest.storage {
            let storageURL = packageURL
                .appendingPathComponent("storage", isDirectory: true)
                .appendingPathComponent("schema.json")
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeJSON(storage, to: storageURL)
        }
        let dataExports = try exportStorageData(
            mode: mode,
            manifest: manifest,
            databaseURL: appStorageDatabaseURL,
            packageURL: packageURL
        )
        if !dataExports.isEmpty {
            try writeJSON(dataExports, to: packageURL
                .appendingPathComponent("storage", isDirectory: true)
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("exports.json")
            )
        }
        let readmeURL = packageURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("README.md")
        try fileManager.createDirectory(at: readmeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(manifest.app.name)\n\nExported ASTRA Workspace App package.\n".utf8)
            .write(to: readmeURL, options: [.atomic])
        try writeJSON(checksums(in: packageURL), to: packageURL.appendingPathComponent("checksums.json"))
        return packageURL
    }

    func validatePackage(at packageURL: URL) -> WorkspaceAppPackageValidationReport {
        var issues: [WorkspaceAppPackageValidationReport.Issue] = []
        let package: WorkspaceAppPackageManifest? = decodePackageFile(
            WorkspaceAppPackageManifest.self,
            in: packageURL,
            path: "/package.json",
            issues: &issues
        )
        let manifest: WorkspaceAppManifest? = decodePackageFile(
            WorkspaceAppManifest.self,
            in: packageURL,
            path: "/manifest.json",
            issues: &issues
        )
        let declaredChecksums: [WorkspaceAppPackageChecksum]? = decodePackageFile(
            [WorkspaceAppPackageChecksum].self,
            in: packageURL,
            path: "/checksums.json",
            issues: &issues
        )

        if let manifest {
            let manifestReport = WorkspaceAppManifestValidator.validate(manifest)
            for issue in manifestReport.issues {
                issues.append(WorkspaceAppPackageValidationReport.Issue(
                    severity: issue.severity == .blocker ? .blocker : .warning,
                    path: "/manifest.json\(issue.path)",
                    message: issue.message
                ))
            }
        }
        if let package, let manifest {
            if package.appID != manifest.app.id {
                issues.append(blocker("/package.json/appID", "Package app ID does not match manifest app ID."))
            }
            if package.sourceManifestDigest != digest(forPackageFile: "manifest.json", in: packageURL) {
                issues.append(blocker("/package.json/sourceManifestDigest", "Package manifest digest does not match manifest.json."))
            }
            validateTrustMetadata(package.trustMetadata, issues: &issues)
            validateImplementationDescriptors(package.implementationDescriptors, issues: &issues)
        }
        if let declaredChecksums {
            validateChecksums(declaredChecksums, packageURL: packageURL, issues: &issues)
            validateAllFilesAreChecksummed(declaredChecksums, packageURL: packageURL, issues: &issues)
        }
        validateDataExports(package: package, packageURL: packageURL, issues: &issues)
        validateNoForbiddenPortableContent(packageURL: packageURL, issues: &issues)

        return WorkspaceAppPackageValidationReport(
            package: package,
            manifest: manifest,
            issues: issues,
            installState: installState(package: package, manifest: manifest, issues: issues)
        )
    }

    @MainActor
    func importPackage(
        at packageURL: URL,
        into workspace: Workspace,
        modelContext: ModelContext
    ) throws -> WorkspaceAppPackageImportResult {
        let report = validatePackage(at: packageURL)
        guard report.canInstall,
              let package = report.package,
              var manifest = report.manifest else {
            throw WorkspaceAppPackageError.invalidPackage(report)
        }
        let packageDigest = packageDigest(at: packageURL)
        let existingIDs = try existingLogicalIDs(in: workspace, modelContext: modelContext)
        manifest = manifestForImport(manifest, existingLogicalIDs: existingIDs)
        let result = try appService.createApp(
            manifest: manifest,
            in: workspace,
            modelContext: modelContext,
            status: .draft,
            sourcePackageID: package.packageID,
            sourcePackageVersion: package.version,
            sourcePackageDigest: packageDigest
        )
        // Seed storage against the PERSISTED manifest (createApp may have suffixed the logical id) so
        // the imported rows land in the app's actual storage path.
        try importStorageData(from: packageURL, manifest: result.manifest, workspace: workspace)
        return WorkspaceAppPackageImportResult(
            app: result.app,
            report: report,
            manifestURL: result.manifestURL
        )
    }

    func checkPackageUpdate(
        for app: WorkspaceApp,
        candidatePackageURL: URL
    ) -> WorkspaceAppPackageUpdateCheck {
        let report = validatePackage(at: candidatePackageURL)
        let package = report.package
        let candidateDigest = packageDigest(at: candidatePackageURL)
        guard let installedPackageID = app.sourcePackageID,
              let installedVersion = app.sourcePackageVersion else {
            return WorkspaceAppPackageUpdateCheck(
                status: .notPackageBacked,
                installedPackageID: app.sourcePackageID,
                installedVersion: app.sourcePackageVersion,
                installedDigest: app.sourcePackageDigest,
                candidatePackageID: package?.packageID,
                candidateVersion: package?.version,
                candidateDigest: candidateDigest,
                validationReport: report
            )
        }
        guard report.canInstall,
              let package else {
            return WorkspaceAppPackageUpdateCheck(
                status: .invalidCandidate,
                installedPackageID: installedPackageID,
                installedVersion: installedVersion,
                installedDigest: app.sourcePackageDigest,
                candidatePackageID: package?.packageID,
                candidateVersion: package?.version,
                candidateDigest: candidateDigest,
                validationReport: report
            )
        }
        guard package.packageID == installedPackageID else {
            return WorkspaceAppPackageUpdateCheck(
                status: .differentPackage,
                installedPackageID: installedPackageID,
                installedVersion: installedVersion,
                installedDigest: app.sourcePackageDigest,
                candidatePackageID: package.packageID,
                candidateVersion: package.version,
                candidateDigest: candidateDigest,
                validationReport: report
            )
        }

        let versionComparison = comparePackageVersions(package.version, installedVersion)
        let status: WorkspaceAppPackageUpdateStatus
        if versionComparison > 0 {
            status = .updateAvailable
        } else if versionComparison < 0 {
            status = .installedVersionNewer
        } else if app.sourcePackageDigest == candidateDigest {
            status = .sameVersionSameDigest
        } else {
            status = .sameVersionDifferentDigest
        }

        return WorkspaceAppPackageUpdateCheck(
            status: status,
            installedPackageID: installedPackageID,
            installedVersion: installedVersion,
            installedDigest: app.sourcePackageDigest,
            candidatePackageID: package.packageID,
            candidateVersion: package.version,
            candidateDigest: candidateDigest,
            validationReport: report
        )
    }

    @MainActor
    private func existingLogicalIDs(
        in workspace: Workspace,
        modelContext: ModelContext
    ) throws -> Set<String> {
        let workspaceID = workspace.id
        let descriptor = FetchDescriptor<WorkspaceApp>(
            predicate: #Predicate<WorkspaceApp> { app in
                app.workspaceID == workspaceID
            }
        )
        return Set(try modelContext.fetch(descriptor).map(\.logicalID))
    }

    private func manifestForImport(
        _ manifest: WorkspaceAppManifest,
        existingLogicalIDs: Set<String>
    ) -> WorkspaceAppManifest {
        guard existingLogicalIDs.contains(manifest.app.id) else {
            return manifest
        }

        var copy = manifest
        let baseID = manifest.app.id
        var suffix = 2
        while existingLogicalIDs.contains("\(baseID)-\(suffix)") {
            suffix += 1
        }
        copy.app.id = "\(baseID)-\(suffix)"
        copy.app.name = "\(manifest.app.name) \(suffix)"
        return copy
    }

    private static func packageRequirement(
        _ requirement: WorkspaceAppRequirement
    ) -> WorkspaceAppPackageContractRequirement {
        WorkspaceAppPackageContractRequirement(
            id: requirement.id,
            contract: requirement.contract,
            minVersion: requirement.minVersion,
            operations: requirement.operations,
            providerHint: requirement.providerHint,
            providerRequired: requirement.providerRequired,
            optional: requirement.optional
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func exportStorageData(
        mode: WorkspaceAppPackageExportMode,
        manifest: WorkspaceAppManifest,
        databaseURL: URL?,
        packageURL: URL
    ) throws -> [WorkspaceAppPackageDataExport] {
        guard let policy = dataPolicy(for: mode),
              let storage = manifest.storage,
              !storage.tables.isEmpty else {
            return []
        }
        guard let databaseURL else {
            throw WorkspaceAppPackageError.missingStorageDatabase(mode)
        }

        let dataRoot = packageURL
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(policy.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        return try storage.tables.map { table in
            let rows = try storageService.records(in: table.name, databaseURL: databaseURL, limit: 10_000)
            let relativePath = "storage/data/\(policy.rawValue)/\(table.name).jsonl"
            let dataURL = packageURL.appendingPathComponent(relativePath)
            try writeJSONLines(rows, to: dataURL)
            return WorkspaceAppPackageDataExport(
                table: table.name,
                policy: policy,
                path: relativePath,
                rowCount: rows.count
            )
        }
    }

    private func importStorageData(
        from packageURL: URL,
        manifest: WorkspaceAppManifest,
        workspace: Workspace
    ) throws {
        guard let exports = try decodeDataExports(at: packageURL), !exports.isEmpty else { return }
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        let tables = Set(manifest.storage?.tables.map(\.name) ?? [])
        for dataExport in exports where tables.contains(dataExport.table) {
            let rows = try readPackageJSONLines(in: packageURL, path: dataExport.path)
            for row in rows {
                try storageService.insertRecord(row, into: dataExport.table, databaseURL: databaseURL)
            }
        }
    }

    private func decodeDataExports(at packageURL: URL) throws -> [WorkspaceAppPackageDataExport]? {
        do {
            let data = try readUTF8ContainedPackageFileData(in: packageURL, path: "storage/data/exports.json")
            return try JSONDecoder().decode([WorkspaceAppPackageDataExport].self, from: data)
        } catch WorkspaceAppPackageFileResolutionError.missing {
            return nil
        }
    }

    private func writeJSONLines(
        _ rows: [[String: WorkspaceAppStorageValue]],
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try rows.map { row in
            String(decoding: try encoder.encode(row), as: UTF8.self)
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: [.atomic])
    }

    private func readPackageJSONLines(
        in packageURL: URL,
        path: String
    ) throws -> [[String: WorkspaceAppStorageValue]] {
        let text = try readUTF8ContainedPackageFileText(in: packageURL, path: path)
        let decoder = JSONDecoder()
        return try text
            .split(whereSeparator: \.isNewline)
            .map { line in
                try decoder.decode([String: WorkspaceAppStorageValue].self, from: Data(String(line).utf8))
            }
    }

    private func dataPolicy(for mode: WorkspaceAppPackageExportMode) -> WorkspaceAppPackageDataExportPolicy? {
        switch mode {
        case .templateOnly:
            nil
        case .templatePlusSampleData:
            .sample
        case .templatePlusSeedData:
            .seed
        case .fullAppExport:
            .full
        }
    }

    private func decodePackageFile<T: Decodable>(
        _ type: T.Type,
        in packageURL: URL,
        path: String,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) -> T? {
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        do {
            let data = try readUTF8ContainedPackageFileData(in: packageURL, path: relativePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch WorkspaceAppPackageFileResolutionError.missing {
            issues.append(blocker(path, "Could not decode required package file \(relativePath): file is missing."))
            return nil
        } catch WorkspaceAppPackageFileResolutionError.invalidPath {
            issues.append(blocker(path, "Package file \(relativePath) must be a regular file inside the package."))
            return nil
        } catch WorkspaceAppPackageFileResolutionError.invalidEncoding {
            issues.append(blocker(path, "Package file \(relativePath) must be valid UTF-8."))
            return nil
        } catch {
            issues.append(blocker(path, "Could not decode required package file \(relativePath): \(error.localizedDescription)"))
            return nil
        }
    }

    private func checksums(in packageURL: URL) throws -> [WorkspaceAppPackageChecksum] {
        let paths = portableFilePaths(in: packageURL)
            .filter { $0 != "checksums.json" }
        return try paths.map { path in
            let data = try readContainedPackageFileData(in: packageURL, path: path)
            return WorkspaceAppPackageChecksum(path: path, sha256: WorkspaceAppService.digest(for: data))
        }
    }

    private func validateChecksums(
        _ checksums: [WorkspaceAppPackageChecksum],
        packageURL: URL,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        for checksum in checksums {
            guard isPortableRelativePath(checksum.path) else {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum path must be relative and portable."))
                continue
            }
            do {
                let data = try readContainedPackageFileData(in: packageURL, path: checksum.path)
                let actual = WorkspaceAppService.digest(for: data)
                if actual != checksum.sha256 {
                    issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum does not match package file."))
                }
            } catch WorkspaceAppPackageFileResolutionError.missing {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum references a missing file."))
                continue
            } catch {
                issues.append(blocker("/checksums.json/\(checksum.path)", "Checksum file must be a regular file inside the package."))
                continue
            }
        }
    }

    private func validateAllFilesAreChecksummed(
        _ checksums: [WorkspaceAppPackageChecksum],
        packageURL: URL,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        let declared = Set(checksums.map(\.path) + ["checksums.json"])
        for path in portableFilePaths(in: packageURL) where !declared.contains(path) {
            issues.append(blocker("/\(path)", "Package file is not listed in checksums.json."))
        }
    }

    private func validateDataExports(
        package: WorkspaceAppPackageManifest?,
        packageURL: URL,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        guard let package else { return }
        let exports: [WorkspaceAppPackageDataExport]
        do {
            exports = try decodeDataExports(at: packageURL) ?? []
        } catch WorkspaceAppPackageFileResolutionError.missing {
            exports = []
        } catch {
            issues.append(dataExportsManifestIssue(for: error))
            exports = []
        }
        if package.exportMode == .fullAppExport {
            issues.append(warning(
                "/package.json/exportMode",
                "Full app export includes app-owned records and may contain sensitive data. Review package data before import."
            ))
        }
        guard !issues.contains(where: { $0.path == "/storage/data/exports.json" && $0.severity == .blocker }) else {
            return
        }
        if package.exportMode == .templateOnly {
            if !exports.isEmpty {
                issues.append(blocker("/storage/data/exports.json", "Template-only packages must not include app records."))
            }
            return
        }
        guard let expectedPolicy = dataPolicy(for: package.exportMode) else { return }
        for dataExport in exports {
            guard dataExport.policy == expectedPolicy else {
                issues.append(blocker("/storage/data/exports.json", "Data export policy does not match package export mode."))
                continue
            }
            guard isPortableRelativePath(dataExport.path),
                  dataExport.path.hasPrefix("storage/data/\(expectedPolicy.rawValue)/"),
                  dataExport.path.hasSuffix(".jsonl") else {
                issues.append(blocker("/storage/data/exports.json", "Data export path must stay within the selected storage data folder."))
                continue
            }
            do {
                let rows = try readPackageJSONLines(in: packageURL, path: dataExport.path)
                if rows.count != dataExport.rowCount {
                    issues.append(blocker("/storage/data/exports.json", "Data export row count does not match \(dataExport.path)."))
                }
            } catch WorkspaceAppPackageFileResolutionError.missing {
                issues.append(blocker("/storage/data/exports.json", "Data export references a missing file."))
                continue
            } catch WorkspaceAppPackageFileResolutionError.invalidEncoding {
                issues.append(blocker("/\(dataExport.path)", "Data export file must be valid UTF-8 JSON Lines."))
                continue
            } catch is DecodingError {
                issues.append(blocker("/\(dataExport.path)", "Data export file must contain valid JSON Lines."))
                continue
            } catch {
                issues.append(blocker("/\(dataExport.path)", "Data export file must be a regular file inside the package."))
                continue
            }
        }
    }

    private func dataExportsManifestIssue(
        for error: Error
    ) -> WorkspaceAppPackageValidationReport.Issue {
        if case WorkspaceAppPackageFileResolutionError.invalidPath = error {
            return blocker(
                "/storage/data/exports.json",
                "Data exports manifest must be a regular file inside the package."
            )
        }
        if case WorkspaceAppPackageFileResolutionError.invalidEncoding = error {
            return blocker(
                "/storage/data/exports.json",
                "Data exports manifest must be valid UTF-8 JSON."
            )
        }
        return blocker(
            "/storage/data/exports.json",
            "Could not decode data exports manifest: \(error.localizedDescription)"
        )
    }

    private func validateImplementationDescriptors(
        _ descriptors: [WorkspaceAppContractImplementation],
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        let registry = WorkspaceAppContractRegistry()
        var seen = Set<String>()
        for (index, descriptor) in descriptors.enumerated() {
            let path = "/package.json/implementationDescriptors/\(index)"
            let id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                issues.append(blocker("\(path)/id", "Implementation descriptor ID is required."))
            } else if !isPortableRelativePath(id) || id.contains("/") {
                issues.append(blocker("\(path)/id", "Implementation descriptor ID must be portable."))
            } else if !seen.insert(id).inserted {
                issues.append(blocker("\(path)/id", "Implementation descriptor ID '\(id)' is duplicated."))
            }
            guard let family = registry.family(id: descriptor.familyID) else {
                issues.append(blocker("\(path)/familyID", "Implementation descriptor references unknown contract family '\(descriptor.familyID)'."))
                continue
            }
            let supportedOperations = Set(family.operations.map(\.name))
            let descriptorOperations = Set(descriptor.operations)
            if descriptor.operations.isEmpty {
                issues.append(blocker("\(path)/operations", "Implementation descriptor must declare supported operations."))
            }
            let unsupported = descriptor.operations.filter { !supportedOperations.contains($0) }
            if !unsupported.isEmpty {
                issues.append(blocker("\(path)/operations", "Implementation descriptor declares unsupported operations: \(unsupported.joined(separator: ", "))."))
            }
            if descriptor.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(blocker("\(path)/provider", "Implementation descriptor provider is required."))
            }
            if descriptor.transport != .native,
               descriptorOperations.contains(where: { operationName in
                   family.operations.first { $0.name == operationName }?.effect == .externalWrite
               }) {
                issues.append(warning("\(path)/transport", "Package-declared \(descriptor.transport.rawValue) external writes require ASTRA approval and are not executed by the current runtime."))
            }
        }
    }

    private func validateTrustMetadata(
        _ metadata: WorkspaceAppPackageTrustMetadata?,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        guard let metadata else { return }
        let signerIdentity = metadata.signerIdentity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trustSource = metadata.trustSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if signerIdentity.isEmpty && trustSource.isEmpty {
            issues.append(blocker("/package.json/trustMetadata", "Package trust metadata must declare a signer identity or trust source."))
        }

        if let packageDigest = metadata.packageDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
           !packageDigest.isEmpty,
           !Self.isHexDigest(packageDigest) {
            issues.append(blocker("/package.json/trustMetadata/packageDigest", "Package trust digest must be a lowercase SHA-256 hex digest."))
        }

        let revocationStatus = metadata.revocationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if revocationStatus == "revoked" {
            issues.append(blocker("/package.json/trustMetadata/revocationStatus", "Package signer trust has been revoked."))
        } else if let revocationStatus,
                  !revocationStatus.isEmpty,
                  !["unknown", "notrevoked", "not_revoked"].contains(revocationStatus) {
            issues.append(warning("/package.json/trustMetadata/revocationStatus", "Package revocation status '\(revocationStatus)' is not recognized by this ASTRA version."))
        }

        let validationResult = metadata.signatureValidationResult?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch validationResult {
        case "valid", nil:
            break
        case "invalid":
            issues.append(blocker("/package.json/trustMetadata/signatureValidationResult", "Package signature validation failed."))
        case "unsigned", "unverified", "missing":
            issues.append(warning("/package.json/trustMetadata/signatureValidationResult", "Package trust metadata is \(validationResult ?? "unverified") and should be reviewed before import."))
        default:
            issues.append(warning("/package.json/trustMetadata/signatureValidationResult", "Package signature validation result '\(validationResult ?? "")' is not recognized by this ASTRA version."))
        }
    }

    private func validateNoForbiddenPortableContent(
        packageURL: URL,
        issues: inout [WorkspaceAppPackageValidationReport.Issue]
    ) {
        for path in portableFilePaths(in: packageURL) where path.hasSuffix(".json") || path.hasSuffix(".jsonl") || path.hasSuffix(".md") {
            guard let data = try? readContainedPackageFileData(in: packageURL, path: path),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let lowercased = text.lowercased()
            let forbiddenKeys = ["api_key", "apikey", "oauth", "password", "secret", "token"]
            if forbiddenKeys.contains(where: { lowercased.contains($0) }) {
                issues.append(blocker("/\(path)", "Package content appears to include credential material."))
            }
            if text.contains(NSHomeDirectory()) || lowercased.contains("/users/") {
                issues.append(blocker("/\(path)", "Package content appears to include an absolute local path."))
            }
        }
    }

    private func readContainedPackageFileData(in packageURL: URL, path: String) throws -> Data {
        let descriptor = try openContainedPackageFile(in: packageURL, path: path)
        defer { close(descriptor) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw WorkspaceAppPackageFileResolutionError.invalidPath
            }
        }
    }

    private func readUTF8ContainedPackageFileData(in packageURL: URL, path: String) throws -> Data {
        let data = try readContainedPackageFileData(in: packageURL, path: path)
        guard String(data: data, encoding: .utf8) != nil else {
            throw WorkspaceAppPackageFileResolutionError.invalidEncoding
        }
        return data
    }

    private func readUTF8ContainedPackageFileText(in packageURL: URL, path: String) throws -> String {
        let data = try readContainedPackageFileData(in: packageURL, path: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceAppPackageFileResolutionError.invalidEncoding
        }
        return text
    }

    private func openContainedPackageFile(in packageURL: URL, path: String) throws -> Int32 {
        guard isPortableRelativePath(path) else {
            throw WorkspaceAppPackageFileResolutionError.invalidPath
        }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw WorkspaceAppPackageFileResolutionError.invalidPath
        }

        let rootPath = packageURL.resolvingSymlinksInPath().standardizedFileURL.path
        var current = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY)
        guard current >= 0 else {
            throw errno == ENOENT ? WorkspaceAppPackageFileResolutionError.missing : WorkspaceAppPackageFileResolutionError.invalidPath
        }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags = isLast
                ? (O_RDONLY | O_NOFOLLOW)
                : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            let next = component.withCString { Darwin.openat(current, $0, flags) }
            let openErrno = errno
            close(current)
            guard next >= 0 else {
                throw openErrno == ENOENT ? WorkspaceAppPackageFileResolutionError.missing : WorkspaceAppPackageFileResolutionError.invalidPath
            }
            current = next
        }

        var stat = stat()
        guard fstat(current, &stat) == 0, (stat.st_mode & S_IFMT) == S_IFREG else {
            close(current)
            throw WorkspaceAppPackageFileResolutionError.invalidPath
        }
        return current
    }

    private func portableFilePaths(in packageURL: URL) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let basePath = packageURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let filePath = url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard filePath.hasPrefix("\(basePath)/") else { return nil }
            return String(filePath.dropFirst(basePath.count + 1))
        }
        .sorted()
    }

    private func isPortableRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("..")
            && !path.contains("\\")
            && !path.contains("\0")
    }

    private static func isHexDigest(_ value: String) -> Bool {
        let hexCharacters = Set("0123456789abcdef")
        return value.count == 64 && value.allSatisfy { character in
            hexCharacters.contains(character)
        }
    }

    private func installState(
        package: WorkspaceAppPackageManifest?,
        manifest: WorkspaceAppManifest?,
        issues: [WorkspaceAppPackageValidationReport.Issue]
    ) -> WorkspaceAppPackageInstallState {
        guard issues.allSatisfy({ $0.severity != .blocker }),
              let manifest else {
            return .blocked
        }
        let registry = WorkspaceAppContractRegistry()
            .including(packageImplementations: package?.implementationDescriptors ?? [])
        let unresolvedRequired = registry.resolveAll(manifest.requirements).contains { !$0.isSatisfied }
        if unresolvedRequired {
            return .needsDependencyMapping
        }
        if manifest.permissions.defaultMode != .readOnly {
            return .needsPermissionReview
        }
        return package == nil ? .decoded : .readyToInstall
    }

    private func digest(forPackageFile path: String, in packageURL: URL) -> String {
        guard let data = try? readContainedPackageFileData(in: packageURL, path: path) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func packageDigest(at packageURL: URL) -> String {
        digest(forPackageFile: "checksums.json", in: packageURL)
    }

    private func comparePackageVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let maxCount = max(left.count, right.count)
        for index in 0..<maxCount {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return -1 }
            if leftValue > rightValue { return 1 }
        }
        return 0
    }

    private func versionComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { component in
                let numericPrefix = component.prefix { $0.isNumber }
                return Int(numericPrefix) ?? 0
            }
    }

    private func blocker(_ path: String, _ message: String) -> WorkspaceAppPackageValidationReport.Issue {
        WorkspaceAppPackageValidationReport.Issue(severity: .blocker, path: path, message: message)
    }

    private func warning(_ path: String, _ message: String) -> WorkspaceAppPackageValidationReport.Issue {
        WorkspaceAppPackageValidationReport.Issue(severity: .warning, path: path, message: message)
    }
}
