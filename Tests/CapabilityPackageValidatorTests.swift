import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability package validator")
struct CapabilityPackageValidatorTests {
    @Test("malformed JSON is blocked")
    func malformedJSONIsBlocked() {
        let report = CapabilityPackageValidator.validate(data: Data("not json".utf8))

        #expect(report.package == nil)
        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code) == [.malformedJSON])
    }

    @Test("local package without governance imports as draft")
    func localPackageWithoutGovernanceImportsAsDraft() throws {
        let data = try encodedData(makePackage(governance: nil))

        let report = CapabilityPackageValidator.validate(data: data, checkPrerequisites: false)

        let package = try #require(report.package)
        #expect(report.canInstall)
        #expect(package.sourceMetadata == .localLibrary())
        #expect(package.governance.approvalStatus == .draft)
        #expect(package.governance.visibility == .adminOnly)
        #expect(package.governance.requiresAdminApproval)
        #expect(report.warnings.map(\.code).contains(.missingGovernance))
    }

    @Test("local import resets self approved governance")
    func localImportResetsSelfApprovedGovernance() throws {
        let data = try encodedData(makePackage(
            governance: .builtInApproved(riskLevel: .high, dataAccess: [.network], externalEffects: [.externalAPIWrite])
        ))

        let report = CapabilityPackageValidator.validate(data: data, checkPrerequisites: false)

        let package = try #require(report.package)
        #expect(report.canInstall)
        #expect(package.governance.approvalStatus == .draft)
        #expect(package.governance.riskLevel == .high)
        #expect(package.governance.dataAccess == [.network])
        #expect(package.governance.externalEffects == [.externalAPIWrite])
        #expect(report.warnings.map(\.code).contains(.approvalReset))
    }

    @Test("duplicate package IDs and filename collisions are blocked")
    func duplicateIDsAndFilenameCollisionsAreBlocked() {
        let installed = [
            makePackage(id: "local.existing", governance: .localDraft()),
            makePackage(id: "local.example", governance: .localDraft())
        ]
        let duplicate = makePackage(id: "local.existing", governance: .localDraft())
        let collision = makePackage(id: "local-example", governance: .localDraft())

        let duplicateReport = CapabilityPackageValidator.validate(
            package: duplicate,
            installedPackages: installed,
            checkPrerequisites: false
        )
        let collisionReport = CapabilityPackageValidator.validate(
            package: collision,
            installedPackages: installed,
            checkPrerequisites: false
        )

        #expect(duplicateReport.blockers.map(\.code).contains(.duplicatePackageID))
        #expect(collisionReport.blockers.map(\.code).contains(.duplicatePackageFilename))
    }

    @Test("unsafe local tool is blocked")
    func unsafeLocalToolIsBlocked() {
        var package = makePackage(governance: .localDraft())
        package.localTools = [
            PluginLocalTool(
                name: "Danger",
                description: "Unsafe",
                icon: "terminal",
                toolType: "cli",
                command: "curl;rm",
                arguments: ""
            )
        ]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.unsafeLocalTool))
    }

    @Test("credentialed HTTP connector is blocked")
    func credentialedHTTPConnectorIsBlocked() {
        var package = makePackage(governance: .localDraft())
        package.connectors = [
            PluginConnector(
                name: "Unsafe API",
                serviceType: "api",
                icon: "network",
                description: "Unsafe connector",
                baseURL: "http://example.com",
                authMethod: "bearer",
                credentialHints: [.init(key: "API_TOKEN", hint: "Token")],
                configHints: [],
                notes: ""
            )
        ]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.unsafeConnector))
    }

    @Test("unknown browser adapter is blocked")
    func unknownBrowserAdapterIsBlocked() {
        var package = makePackage(governance: .localDraft())
        package.browserAdapters = ["unknown-browser"]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.unknownBrowserAdapter))
    }

    @Test("unsafe MCP server is blocked")
    func unsafeMCPServerIsBlocked() {
        var package = makePackage(governance: .localDraft())
        package.mcpServers = [
            PluginMCPServer(
                id: "danger",
                displayName: "Danger MCP",
                transport: .stdio,
                command: "npx",
                arguments: ["server", ";", "rm"]
            )
        ]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.unsafeMCPServer))
    }

    @Test("missing prerequisites are warnings")
    func missingPrerequisitesAreWarnings() {
        var package = makePackage(governance: .localDraft())
        package.prerequisites = [
            CLIPrerequisite(
                binary: "astra-missing-binary-\(UUID().uuidString)",
                displayName: "Missing CLI",
                purpose: "Test warning",
                installHint: "Install it."
            )
        ]

        let report = CapabilityPackageValidator.validate(
            package: package,
            detectExecutable: { _ in "" }
        )

        #expect(report.canInstall)
        #expect(report.warnings.map(\.code).contains(.missingPrerequisite))
    }

    @Test("documented example packages validate without blockers")
    func documentedExamplesValidateWithoutBlockers() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let examplesRoot = repoRoot
            .appendingPathComponent("docs")
            .appendingPathComponent("capabilities")
            .appendingPathComponent("examples")
        let files = try FileManager.default.contentsOfDirectory(
            at: examplesRoot,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        #expect(files.count >= 5)
        for file in files {
            let report = CapabilityPackageValidator.validate(
                data: try Data(contentsOf: file),
                sourceURL: file,
                checkPrerequisites: false
            )
            #expect(report.blockers.isEmpty, "\(file.lastPathComponent): \(report.summary)")
            #expect(report.package != nil)
        }
    }

    @Test("top level capability library packages validate without blockers")
    func topLevelCapabilityLibraryPackagesValidateWithoutBlockers() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let libraryRoot = repoRoot.appendingPathComponent("capabilities")
        let files = try capabilityPackageFiles(in: libraryRoot)

        #expect(!files.isEmpty)
        for file in files {
            let report = CapabilityPackageValidator.validate(
                data: try Data(contentsOf: file),
                sourceURL: file,
                checkPrerequisites: false
            )
            #expect(report.blockers.isEmpty, "\(file.lastPathComponent): \(report.summary)")
            #expect(report.package != nil)
        }
    }
}

@Suite("Capability package importer")
struct CapabilityPackageImporterTests {
    @Test("malformed import does not write package file")
    func malformedImportDoesNotWritePackageFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let badURL = root.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: badURL)

        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let importer = CapabilityPackageImporter(library: CapabilityLibrary(directory: libraryRoot))

        do {
            _ = try importer.importFile(at: badURL, checkPrerequisites: false)
            Issue.record("Malformed JSON import should fail")
        } catch let error as CapabilityPackageImportError {
            #expect(error.report.blockers.map(\.code) == [.malformedJSON])
        }

        let files = try? FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil)
        #expect(files?.filter { $0.pathExtension == "json" }.isEmpty ?? true)
    }

    @Test("valid import writes normalized local package")
    func validImportWritesNormalizedLocalPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-import-valid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("package.json")
        try encodedData(makePackage(governance: nil)).write(to: packageURL)

        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let importer = CapabilityPackageImporter(library: CapabilityLibrary(directory: libraryRoot))

        let result = try importer.importFile(at: packageURL, checkPrerequisites: false)
        let installed = try #require(importer.library.installedPackage(id: result.package.id))

        #expect(FileManager.default.fileExists(atPath: result.installedURL.path))
        #expect(installed.sourceMetadata == .localLibrary())
        #expect(installed.governance.approvalStatus == .draft)
    }

    @Test("validated import rechecks current library before writing")
    func validatedImportRechecksCurrentLibraryBeforeWriting() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-import-recheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("package.json")
        let packageID = "local.recheck-\(UUID().uuidString)"
        try encodedData(makePackage(id: packageID, governance: nil)).write(to: packageURL)

        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let importer = CapabilityPackageImporter(library: CapabilityLibrary(directory: libraryRoot))
        let report = importer.validateFile(at: packageURL, checkPrerequisites: false)

        var existing = makePackage(id: packageID, governance: .localDraft())
        existing.version = "9.0.0"
        try importer.library.install(existing, sourceMetadata: .localLibrary())

        do {
            _ = try importer.importValidatedPackage(report)
            Issue.record("Validated import should re-check duplicate package IDs before writing")
        } catch let error as CapabilityPackageImportError {
            #expect(error.report.blockers.map(\.code).contains(.duplicatePackageID))
        }

        let installed = try #require(importer.library.installedPackage(id: packageID))
        #expect(installed.version == "9.0.0")
    }

    @Test("developer script validates package JSON")
    func developerScriptValidatesPackageJSON() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let package = makePackage(id: "local.script-\(UUID().uuidString)", governance: nil)
        let packageURL = root.appendingPathComponent("package.json")
        try encodedData(package).write(to: packageURL)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot
            .appendingPathComponent("script")
            .appendingPathComponent("capability_package.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "validate", packageURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "Script failed: \(text)")
        #expect(text.contains("OK capability package is valid for local import"))
    }

    @Test("developer script validates capability directories")
    func developerScriptValidatesCapabilityDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let nestedRoot = libraryRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)

        try encodedData(makePackage(id: "local.script-dir-one-\(UUID().uuidString)", governance: nil))
            .write(to: libraryRoot.appendingPathComponent("one.json"))
        try encodedData(makePackage(id: "local.script-dir-two-\(UUID().uuidString)", governance: nil))
            .write(to: nestedRoot.appendingPathComponent("two.json"))

        let result = try runCapabilityPackageScript(arguments: ["validate-dir", libraryRoot.path])

        #expect(result.status == 0, "Script failed: \(result.output)")
        #expect(result.output.contains("OK 2 capability packages are valid for local import"))
    }

    @Test("developer script install directory writes normalized packages to dev library")
    func developerScriptInstallDirectoryWritesNormalizedPackagesToDevLibrary() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-dir-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)

        let firstID = "local.script-install-one-\(UUID().uuidString)"
        let secondID = "local.script-install-two-\(UUID().uuidString)"
        var firstPackage = makePackage(id: firstID, governance: .builtInApproved())
        firstPackage.sourceMetadata = .builtIn()
        try encodedData(firstPackage)
            .write(to: libraryRoot.appendingPathComponent("one.json"))
        try encodedData(makePackage(id: secondID, governance: nil))
            .write(to: libraryRoot.appendingPathComponent("two.json"))

        let result = try runCapabilityPackageScript(
            arguments: ["install-dev-dir", libraryRoot.path],
            home: homeRoot
        )

        let devLibrary = homeRoot
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("AstraDev")
            .appendingPathComponent("Capabilities")
        let installedFiles = try FileManager.default.contentsOfDirectory(
            at: devLibrary,
            includingPropertiesForKeys: nil
        )
        let decoder = JSONDecoder()
        let installedPackages = try installedFiles
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(PluginPackage.self, from: Data(contentsOf: $0)) }

        #expect(result.status == 0, "Script failed: \(result.output)")
        #expect(result.output.contains("Installed \(firstID)"))
        #expect(result.output.contains("Installed \(secondID)"))
        #expect(Set(installedPackages.map(\.id)) == [firstID, secondID])
        #expect(installedPackages.allSatisfy { $0.sourceMetadata == .localLibrary() })
        #expect(installedPackages.allSatisfy { $0.governance.approvalStatus == .draft })
        #expect(installedPackages.allSatisfy { $0.governance.visibility == .adminOnly })
        #expect(installedPackages.allSatisfy { $0.governance.approvedBy == nil })
        #expect(installedPackages.allSatisfy { $0.governance.approvedAt == nil })
    }

    @Test("developer script install directory rejects duplicate package IDs without partial writes")
    func developerScriptInstallDirectoryRejectsDuplicateIDsWithoutPartialWrites() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-dir-duplicate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)

        let packageID = "local.script-duplicate-\(UUID().uuidString)"
        try encodedData(makePackage(id: packageID, governance: nil))
            .write(to: libraryRoot.appendingPathComponent("one.json"))
        var secondPackage = makePackage(id: packageID, governance: nil)
        secondPackage.version = "1.0.1"
        try encodedData(secondPackage)
            .write(to: libraryRoot.appendingPathComponent("two.json"))

        let result = try runCapabilityPackageScript(
            arguments: ["install-dev-dir", libraryRoot.path],
            home: homeRoot
        )

        #expect(result.status != 0)
        #expect(result.output.contains("duplicatePackageID"))
        let devLibrary = homeRoot
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("AstraDev")
            .appendingPathComponent("Capabilities")
        let installedFiles = try? FileManager.default.contentsOfDirectory(
            at: devLibrary,
            includingPropertiesForKeys: nil
        )
        #expect(installedFiles?.isEmpty ?? true)
    }
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

private func capabilityPackageFiles(in directory: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    )
    var files: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: Set(keys))
        if values.isRegularFile == true && url.pathExtension == "json" {
            files.append(url)
        }
    }
    return files.sorted { $0.path < $1.path }
}

private func runCapabilityPackageScript(
    arguments: [String],
    home: URL? = nil
) throws -> ProcessResult {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scriptURL = repoRoot
        .appendingPathComponent("script")
        .appendingPathComponent("capability_package.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptURL.path] + arguments
    if let home {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
    }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    return ProcessResult(
        status: process.terminationStatus,
        output: String(data: data, encoding: .utf8) ?? ""
    )
}

private func makePackage(
    id: String = "local.test-package",
    governance: CapabilityGovernance?
) -> PluginPackage {
    PluginPackage(
        id: id,
        name: "Test Package",
        icon: "puzzlepiece.extension",
        description: "Package for validation tests",
        author: "Tests",
        category: "Tests",
        tags: ["test"],
        version: "1.0.0",
        setupGuide: "Use for tests.",
        skills: [
            PluginSkill(
                name: "Test Skill",
                icon: "sparkles",
                description: "Test skill",
                allowedTools: ["Read"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Stay read-only.",
                environmentKeys: [],
                environmentValues: []
            )
        ],
        connectors: [],
        localTools: [],
        templates: [],
        governance: governance
    )
}

private func encodedData(_ package: PluginPackage) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var object = try JSONSerialization.jsonObject(with: try encoder.encode(package)) as! [String: Any]
    if package.governance == CapabilityGovernance.defaultGovernance(for: package.sourceMetadata) {
        object.removeValue(forKey: "governance")
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}
