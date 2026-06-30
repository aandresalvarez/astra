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

    @Test("local package with null governance imports as draft")
    func localPackageWithNullGovernanceImportsAsDraft() throws {
        var object = try JSONSerialization.jsonObject(
            with: encodedData(makePackage(governance: nil))
        ) as! [String: Any]
        object["governance"] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])

        let report = CapabilityPackageValidator.validate(data: data, checkPrerequisites: false)

        let package = try #require(report.package)
        #expect(report.canInstall)
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

    @Test("package identity rejects case-only installed ID collisions")
    func packageIdentityRejectsCaseOnlyInstalledIDCollisions() {
        let installed = [makePackage(id: "local.casepkg", governance: .localDraft())]
        let casedReplacement = makePackage(id: "Local.CasePkg", governance: .localDraft())

        let report = CapabilityPackageValidator.validate(
            package: casedReplacement,
            installedPackages: installed,
            allowReplacingExistingPackageID: true,
            checkPrerequisites: false
        )

        #expect(report.blockers.map(\.code).contains(.duplicatePackageID))
    }

    @Test("package identity rejects whitespace punctuation unicode and malformed semver")
    func packageIdentityRejectsUnsafeLiterals() {
        let invalidIDs = [
            " local.trimmed",
            "local.trimmed ",
            ".local.leading-dot",
            "-local.leading-hyphen",
            "local.café"
        ]
        for id in invalidIDs {
            let report = CapabilityPackageValidator.validate(
                package: makePackage(id: id, governance: .localDraft()),
                checkPrerequisites: false
            )
            #expect(report.blockers.map(\.code).contains(.invalidPackageID), "\(id) should be invalid")
        }

        let invalidVersions = [
            " 1.0.0",
            "1.0.0 ",
            "1.2.beta",
            "1.2.3.4",
            "1"
        ]
        for version in invalidVersions {
            var package = makePackage(id: "local.invalid-version-\(UUID().uuidString)", governance: .localDraft())
            package.version = version
            let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
            #expect(report.blockers.map(\.code).contains(.invalidVersion), "\(version) should be invalid")
        }
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

    @Test("local tool interpreter inline execution defaults are blocked")
    func localToolInterpreterInlineExecutionDefaultsAreBlocked() {
        let cases: [(String, String)] = [
            ("/bin/bash", "-c id"),
            ("python3", "-c print")
        ]

        for (command, arguments) in cases {
            var package = makePackage(id: "local.inline-\(UUID().uuidString)", governance: .localDraft())
            package.localTools = [
                PluginLocalTool(
                    name: "Inline",
                    description: "Unsafe inline interpreter",
                    icon: "terminal",
                    toolType: "cli",
                    command: command,
                    arguments: arguments
                )
            ]

            let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

            #expect(!report.canInstall)
            #expect(report.blockers.contains { issue in
                issue.code == .unsafeLocalTool
                    && issue.message.contains("interpreter execution flag")
            }, "\(command) \(arguments) should be blocked")
        }
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
                command: "python3",
                arguments: ["-c", "print"]
            )
        ]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.unsafeMCPServer))
        #expect(report.blockers.contains { $0.message.contains("interpreter execution flag") })
    }

    @Test("unsafe MCP control-plane metadata is blocked")
    func unsafeMCPControlPlaneMetadataIsBlocked() {
        var package = makePackage(governance: .localDraft())
        package.mcpServers = [
            PluginMCPServer(
                id: "google-workspace",
                displayName: "Google Workspace",
                transport: .http,
                url: URL(string: "https://mcp.example.com/google"),
                controlPlane: MCPControlPlaneMetadata(
                    runtimeBindings: [
                        MCPRuntimeBindingTemplate(
                            id: "authorization-header",
                            destination: .httpHeader,
                            name: "Authorization",
                            template: [
                                .literal("Bearer ya29.raw-access-token-that-must-not-serialize")
                            ]
                        )
                    ]
                )
            )
        ]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.unsafeMCPServer))
        #expect(report.blockers.contains { $0.message.contains("control-plane") })
        #expect(report.blockers.contains {
            $0.message.contains("runtime binding authorization-header is invalid: literal value must not contain a raw secret")
        })
        #expect(!report.blockers.contains { $0.message.contains("literalValueMustNotContainRawSecret") })
    }

    @Test("mutable MCP install source is surfaced as a warning")
    func mutableMCPInstallSourceIsWarning() {
        var package = makePackage(governance: .localDraft())
        package.mcpServers = [
            PluginMCPServer(
                id: "versionless",
                displayName: "Versionless MCP",
                transport: .stdio,
                command: "npx",
                arguments: ["-y", "@acme/mcp-server"],
                installSource: PluginMCPInstallSource(
                    kind: .npm,
                    identifier: "@acme/mcp-server",
                    installMode: .npx
                )
            )
        ]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(report.canInstall)
        #expect(report.warnings.map(\.code).contains(.mcpInstallSourcePolicy))
        #expect(report.warnings.contains { $0.message.contains("mutable") })
    }

    @Test("blocked MCP install source is surfaced as a blocker")
    func blockedMCPInstallSourceIsBlocker() {
        var package = makePackage(governance: .localDraft())
        package.mcpServers = [
            PluginMCPServer(
                id: "remote",
                displayName: "Remote MCP",
                transport: .http,
                url: URL(string: "http://example.com/mcp"),
                installSource: PluginMCPInstallSource(
                    kind: .remoteHTTP,
                    identifier: "http://example.com/mcp",
                    installMode: .remote
                )
            )
        ]

        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.mcpInstallSourcePolicy))
        #expect(report.blockers.contains { $0.message.contains("HTTPS") })
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

    @Test("asset icon path must be local relative and under assets")
    func assetIconPathMustBeLocalRelativeAndUnderAssets() {
        let invalidValues = [
            "https://example.com/icon.svg",
            "/tmp/icon.svg",
            "../icon.svg",
            "icons/icon.svg",
            "assets/../icon.svg",
            "assets/icon.gif"
        ]

        for value in invalidValues {
            var package = makePackage(governance: .localDraft())
            package.iconDescriptor = .asset(value, fallbackSystemName: package.icon)

            let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

            #expect(report.blockers.map(\.code).contains(.invalidIconAsset), "\(value) should be blocked")
        }
    }

    @Test("capability folder validation requires declared icon asset to exist")
    func capabilityFolderValidationRequiresDeclaredIconAssetToExist() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-missing-asset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var package = makePackage(governance: .localDraft())
        package.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: package.icon)
        try encodedData(package).write(to: root.appendingPathComponent("capability.json"))

        let report = CapabilityPackageValidator.validateSource(at: root, checkPrerequisites: false)

        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code).contains(.missingIconAsset))
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

    @Test("unreadable import reports unreadable file")
    func unreadableImportReportsUnreadableFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-import-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingURL = root.appendingPathComponent("missing.json")

        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let importer = CapabilityPackageImporter(library: CapabilityLibrary(directory: libraryRoot))

        let report = importer.validateFile(at: missingURL, checkPrerequisites: false)

        #expect(report.package == nil)
        #expect(!report.canInstall)
        #expect(report.blockers.map(\.code) == [.unreadableFile])
        #expect(report.blockers.first?.message.contains(missingURL.path) == true)
        #expect(report.blockers.first?.message != "ASTRA could not read \(missingURL.lastPathComponent).")
    }

    @Test("import overview avoids duplicate summary fallback")
    func importOverviewAvoidsDuplicateSummaryFallback() {
        var emptyDescription = makePackage(governance: nil)
        emptyDescription.description = ""
        let summary = emptyDescription.contentSummary

        #expect(CapabilityImportPresentation.overviewDescription(
            for: emptyDescription,
            contentSummary: summary
        ) == "No description provided.")
        #expect(!CapabilityImportPresentation.shouldShowContentSummary(for: emptyDescription))

        var described = emptyDescription
        described.description = "Human-authored package description."
        #expect(CapabilityImportPresentation.overviewDescription(
            for: described,
            contentSummary: summary
        ) == "Human-authored package description.")
        #expect(CapabilityImportPresentation.shouldShowContentSummary(for: described))
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

    @Test("valid folder import copies declared icon asset")
    func validFolderImportCopiesDeclaredIconAsset() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-import-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let assetsRoot = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><circle cx=\"0.5\" cy=\"0.5\" r=\"0.5\"/></svg>".utf8)
            .write(to: assetsRoot.appendingPathComponent("icon.svg"))

        var package = makePackage(id: "local.folder-import-\(UUID().uuidString)", governance: nil)
        package.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: package.icon)
        try encodedData(package).write(to: sourceRoot.appendingPathComponent("capability.json"))

        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let importer = CapabilityPackageImporter(library: CapabilityLibrary(directory: libraryRoot))

        let result = try importer.importFile(at: sourceRoot, checkPrerequisites: false)
        let installed = try #require(importer.library.installedPackage(id: result.package.id))
        let copiedIcon = result.installedURL
            .deletingLastPathComponent()
            .appendingPathComponent("assets/icon.svg")

        #expect(result.installedURL.lastPathComponent == "capability.json")
        #expect(FileManager.default.fileExists(atPath: copiedIcon.path))
        #expect(installed.iconDescriptor == .asset("assets/icon.svg", fallbackSystemName: package.icon))
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

    @Test("developer script avoids Python 3.9-only built-in generics")
    func developerScriptAvoidsPython39OnlyBuiltInGenerics() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot
            .appendingPathComponent("script")
            .appendingPathComponent("capability_package.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(!script.contains("list["))
        #expect(!script.contains("dict["))
    }

    @Test("developer script reports unreadableFile for missing package")
    func developerScriptReportsUnreadableFileForMissingPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingURL = root.appendingPathComponent("missing.json")

        let result = try runCapabilityPackageScript(arguments: ["validate", missingURL.path])

        #expect(result.status != 0)
        #expect(result.output.contains("unreadableFile"))
        #expect(!result.output.contains("BLOCKER unreadable:"))
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

    @Test("developer script validates single capability folder with icon asset")
    func developerScriptValidatesSingleCapabilityFolderWithIconAsset() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("asset-package", isDirectory: true)
        let assets = packageRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
            .write(to: assets.appendingPathComponent("icon.svg"))
        var package = makePackage(id: "local.script-folder-\(UUID().uuidString)", governance: nil)
        package.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: package.icon)
        try encodedData(package).write(to: packageRoot.appendingPathComponent("capability.json"))

        let result = try runCapabilityPackageScript(arguments: ["validate", packageRoot.path])

        #expect(result.status == 0, "Script failed: \(result.output)")
        #expect(result.output.contains("OK capability package is valid for local import"))
    }

    @Test("developer script install folder copies icon asset")
    func developerScriptInstallFolderCopiesIconAsset() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-folder-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("asset-package", isDirectory: true)
        let assets = packageRoot.appendingPathComponent("assets", isDirectory: true)
        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><circle cx=\"0.5\" cy=\"0.5\" r=\"0.5\"/></svg>".utf8)
            .write(to: assets.appendingPathComponent("icon.svg"))
        let packageID = "local.script-folder-install-\(UUID().uuidString)"
        var package = makePackage(id: packageID, governance: nil)
        package.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: package.icon)
        try encodedData(package).write(to: packageRoot.appendingPathComponent("capability.json"))

        let result = try runCapabilityPackageScript(arguments: ["install-dev", packageRoot.path], home: homeRoot)

        let installedRoot = homeRoot
            .appendingPathComponent("Library/Application Support/AstraDev/Capabilities", isDirectory: true)
            .appendingPathComponent(CapabilityLibrary.safeFileName(for: packageID), isDirectory: true)
        let manifest = installedRoot.appendingPathComponent("capability.json")
        let icon = installedRoot.appendingPathComponent("assets/icon.svg")
        #expect(result.status == 0, "Script failed: \(result.output)")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: icon.path))
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

    @Test("developer script rejects invalid package identity without partial writes")
    func developerScriptRejectsInvalidIdentityWithoutPartialWrites() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-invalid-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)

        var whitespaceObject = try JSONSerialization.jsonObject(
            with: encodedData(makePackage(id: "local.script-bad-identity", governance: nil))
        ) as! [String: Any]
        whitespaceObject["id"] = " local.script-bad-identity"
        whitespaceObject["version"] = "1.2.beta"
        try JSONSerialization.data(withJSONObject: whitespaceObject, options: [.prettyPrinted, .sortedKeys])
            .write(to: libraryRoot.appendingPathComponent("whitespace.json"))

        var typedObject = whitespaceObject
        typedObject["id"] = 42
        typedObject["version"] = 42
        try JSONSerialization.data(withJSONObject: typedObject, options: [.prettyPrinted, .sortedKeys])
            .write(to: libraryRoot.appendingPathComponent("typed.json"))

        let result = try runCapabilityPackageScript(
            arguments: ["install-dev-dir", libraryRoot.path],
            home: homeRoot
        )

        #expect(result.status != 0)
        #expect(result.output.contains("invalidPackageID"))
        #expect(result.output.contains("invalidVersion"))
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

    @Test("developer script rejects malformed collection fields without traceback")
    func developerScriptRejectsMalformedCollectionFieldsWithoutTraceback() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-malformed-collections-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var object = try JSONSerialization.jsonObject(
            with: encodedData(makePackage(id: "local.script-malformed-collections-\(UUID().uuidString)", governance: nil))
        ) as! [String: Any]
        object["localTools"] = ["not an object"]
        object["connectors"] = ["not an object"]
        object["browserAdapters"] = [["not": "a string"]]
        object["mcpServers"] = ["not an object"]
        let packageURL = root.appendingPathComponent("package.json")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: packageURL)

        let result = try runCapabilityPackageScript(arguments: ["validate", packageURL.path])

        #expect(result.status != 0)
        #expect(result.output.contains("malformedJSON"))
        #expect(!result.output.contains("Traceback"))
    }

    @Test("developer script reports installed filename collision distinctly")
    func developerScriptReportsInstalledFilenameCollisionDistinctly() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-capability-script-installed-collision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        let devLibrary = homeRoot
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("AstraDev")
            .appendingPathComponent("Capabilities")
        try FileManager.default.createDirectory(at: devLibrary, withIntermediateDirectories: true)

        let suffix = UUID().uuidString.lowercased()
        let existingID = "local-script-collision-\(suffix)"
        let candidateID = "local.script.collision-\(suffix)"
        try encodedData(makePackage(id: existingID, governance: nil))
            .write(to: devLibrary.appendingPathComponent("\(existingID).json"))
        let candidateURL = root.appendingPathComponent("candidate.json")
        try encodedData(makePackage(id: candidateID, governance: nil))
            .write(to: candidateURL)

        let result = try runCapabilityPackageScript(
            arguments: ["install-dev", candidateURL.path],
            home: homeRoot
        )

        #expect(result.status != 0)
        #expect(result.output.contains("duplicatePackageFilename"))
        #expect(!result.output.contains("duplicatePackageID"))
        let installed = try JSONDecoder().decode(
            PluginPackage.self,
            from: Data(contentsOf: devLibrary.appendingPathComponent("\(existingID).json"))
        )
        #expect(installed.id == existingID)
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
