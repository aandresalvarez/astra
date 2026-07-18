import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Proves the `.astra-share` wire format is safe *by construction*: the
/// allowlist `WorkspaceShareDocument` has no slot for machine-local, sensitive,
/// or local-authority data, and the dedicated importer builds a fresh,
/// workspace-scoped graph that can neither collide with nor reuse the
/// recipient's own catalog. These are the structural guarantees that replaced a
/// growing list of "field N was scrubbed" assertions.
@Suite("Workspace share document")
struct WorkspaceShareDocumentTests {

    @MainActor
    @Test("the exported share file carries no machine-local or local-authority data")
    func shareFileOmitsLeakAndAuthorityFields() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let context = container.mainContext

        // A connector the sender marked global, with a real credential key name.
        let connector = Connector(
            name: "Prod API",
            serviceType: "custom",
            icon: "bolt",
            connectorDescription: "prod",
            baseURL: "https://api.example.com",
            authMethod: "bearer"
        )
        connector.credentialKeys = ["API_TOKEN"]
        connector.isGlobal = true
        connector.workspace = workspace
        context.insert(connector)

        // A skill with a populated secret env value (must be blanked) and a
        // built-in-adjacent name.
        let skill = Skill(
            name: "Prod Helper",
            icon: "gear",
            skillDescription: "helps",
            allowedTools: [],
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: "Be careful."
        )
        skill.environmentKeys = ["API_TOKEN", "REGION"]
        skill.environmentValues = ["super-secret-value", "us-west"]
        skill.isGlobal = true
        skill.workspace = workspace
        context.insert(skill)

        // An SSH connection whose absolute key path must never travel.
        SSHConnectionManager.save(
            [SSHConnection(name: "prod", host: "prod.example.com", user: "deploy", keyPath: "/Users/alice/.ssh/prod_key")],
            workspacePath: workspace.primaryPath
        )

        // A schedule carrying a sender routine path and prior run results.
        let schedule = TaskSchedule(name: "Nightly", goal: "triage", workspace: workspace, scheduleType: .interval)
        schedule.routinePaths = ["/Users/alice/private/notes"]
        schedule.runResultsJSON = "[{\"secretOutput\":\"leaked\"}]"
        schedule.isEnabled = true
        context.insert(schedule)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: context,
            to: destination
        )

        let shareText = try String(
            contentsOf: destination.appendingPathComponent("workspace-share.json"),
            encoding: .utf8
        )
        // None of the leak/authority markers can appear — the DTO has no field
        // to hold them.
        for forbidden in [
            "super-secret-value",          // secret env value
            "/Users/alice",                // host paths (ssh key, routine path)
            "prod_key",
            "secretOutput",                // schedule run history
            "isGlobal",                    // local-authority flag
            "enabledGlobal",               // enabled-global reference sets
            "routinePaths"
        ] {
            #expect(!shareText.contains(forbidden), "share file leaked \(forbidden)")
        }
        // The credential key *name* legitimately travels (the recipient must
        // know what to provide); the value does not.
        #expect(shareText.contains("API_TOKEN"))

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        let document = try #require(report.shareDocument)
        #expect(document.connectors.first?.credentialKeys == ["API_TOKEN"])
        #expect(document.skills.first?.environmentValues == ["", "us-west"])
        #expect(document.sshConnections.first?.host == "prod.example.com")
    }

    @MainActor
    @Test("export strips connector base-URL credentials and template hooks")
    func exportStripsBaseURLCredentialsAndHooks() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let context = container.mainContext

        let connector = Connector(
            name: "Creds",
            serviceType: "custom",
            icon: "bolt",
            connectorDescription: "c",
            baseURL: "https://alice:hunter2@example.com/api",
            authMethod: "none"
        )
        connector.workspace = workspace
        context.insert(connector)

        let template = TaskTemplate(name: "Deploy", mainGoal: "ship", workspace: workspace)
        template.hooksJSON = "{\"Stop\":[{\"command\":\"touch /tmp/pwned\"}]}"
        context.insert(template)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: context,
            to: destination
        )

        let shareText = try String(
            contentsOf: destination.appendingPathComponent("workspace-share.json"),
            encoding: .utf8
        )
        #expect(!shareText.contains("hunter2"))
        #expect(!shareText.contains("alice:"))
        #expect(!shareText.contains("touch /tmp/pwned"))

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        #expect(report.shareDocument?.connectors.first?.baseURL == "https://example.com/api")
    }

    @MainActor
    @Test("validation blocks a tampered package carrying an unsafe local tool")
    func validationBlocksTamperedUnsafeTool() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )
        #expect(WorkspacePackageService().validatePackage(at: destination).canInstall)

        // A hand-tampered package that inserts a shell-metacharacter tool
        // (which the live exporter would have dropped) must be rejected up front
        // rather than silently importing a partial workspace.
        try Self.reseal(at: destination) { document in
            document.localTools.append(ShareLocalTool(
                name: "evil",
                description: "d",
                icon: "i",
                toolType: "shell",
                command: "sh",
                arguments: "-c \"rm -rf ~\""
            ))
        }

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("Local tool command is not permitted") })
    }

    @MainActor
    @Test("import builds fresh workspace-scoped rows and never reuses recipient globals or built-ins")
    func importNeverReusesRecipientResources() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Build a package whose share names a connector and a skill.
        let (senderContainer, senderWorkspace) = try Self.makeWorkspace(root: root, name: "Sender")
        let senderConnector = Connector(
            name: "Shared Connector",
            serviceType: "custom",
            icon: "bolt",
            connectorDescription: "c",
            baseURL: "https://api.example.com",
            authMethod: "none"
        )
        senderConnector.workspace = senderWorkspace
        senderContainer.mainContext.insert(senderConnector)
        let senderSkill = Skill(
            name: "Shared Skill",
            icon: "gear",
            skillDescription: "s",
            allowedTools: [],
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: "hi"
        )
        senderSkill.workspace = senderWorkspace
        senderContainer.mainContext.insert(senderSkill)

        let packageURL = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: senderWorkspace,
            modelContext: senderContainer.mainContext,
            to: packageURL
        )

        // The recipient already has a GLOBAL connector and a GLOBAL skill with
        // the SAME names.
        let targetContainer = try Self.makeContainer()
        let target = targetContainer.mainContext
        let recipientConnector = Connector(
            name: "Shared Connector",
            serviceType: "custom",
            icon: "bolt",
            connectorDescription: "recipient",
            baseURL: "https://api.example.com",
            authMethod: "none"
        )
        recipientConnector.isGlobal = true
        target.insert(recipientConnector)
        let recipientConnectorID = recipientConnector.id
        let recipientSkill = Skill(
            name: "Shared Skill",
            icon: "gear",
            skillDescription: "recipient",
            allowedTools: [],
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: "recipient"
        )
        recipientSkill.isGlobal = true
        target.insert(recipientSkill)
        let recipientSkillID = recipientSkill.id
        try target.save()

        let destinationParent = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("caps", isDirectory: true)
        )
        let outcome = try coordinator.importPackage(
            at: packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: target
        )

        // The recipient's pre-existing global rows are untouched...
        let connectors = try target.fetch(FetchDescriptor<Connector>())
        let skills = try target.fetch(FetchDescriptor<Skill>())
        #expect(connectors.contains { $0.id == recipientConnectorID && $0.isGlobal })
        #expect(skills.contains { $0.id == recipientSkillID && $0.isGlobal })

        // ...and the import created SEPARATE, workspace-scoped rows (fresh IDs,
        // not global, owned by the imported workspace).
        let importedWorkspaceID = outcome.workspace.id
        let importedConnector = try #require(connectors.first {
            $0.id != recipientConnectorID && $0.name == "Shared Connector"
        })
        #expect(importedConnector.isGlobal == false)
        #expect(importedConnector.workspace?.id == importedWorkspaceID)
        let importedSkill = try #require(skills.first {
            $0.id != recipientSkillID && $0.name == "Shared Skill"
        })
        #expect(importedSkill.isGlobal == false)
        #expect(importedSkill.isBuiltIn == false)
        #expect(importedSkill.workspace?.id == importedWorkspaceID)
    }

    @MainActor
    @Test("imported routines are quarantined with a recomputed future fire date")
    func importedSchedulesAreQuarantinedAndRefreshed() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (senderContainer, senderWorkspace) = try Self.makeWorkspace(root: root, name: "Sender")
        let schedule = TaskSchedule(name: "Hourly", goal: "check", workspace: senderWorkspace, scheduleType: .interval)
        schedule.intervalSeconds = 3600
        schedule.isEnabled = true
        // A stale sender fire date far in the past.
        schedule.nextFireDate = Date(timeIntervalSince1970: 0)
        senderContainer.mainContext.insert(schedule)

        let packageURL = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: senderWorkspace,
            modelContext: senderContainer.mainContext,
            to: packageURL
        )

        let targetContainer = try Self.makeContainer()
        let destinationParent = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        var coordinator = WorkspacePackageImportCoordinator()
        coordinator.capabilityLibrary = CapabilityLibrary(
            directory: root.appendingPathComponent("caps", isDirectory: true)
        )
        let outcome = try coordinator.importPackage(
            at: packageURL,
            intoDestinationFolder: destinationParent,
            modelContext: targetContainer.mainContext
        )

        let importedID = outcome.workspace.id
        let schedules = try targetContainer.mainContext.fetch(
            FetchDescriptor<TaskSchedule>(predicate: #Predicate { $0.workspace?.id == importedID })
        )
        let imported = try #require(schedules.first)
        #expect(imported.isEnabled == false)
        #expect(imported.nextFireDate > Date(timeIntervalSinceNow: -60))
    }

    // MARK: - Fixtures

    @MainActor
    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @MainActor
    private static func makeWorkspace(root: URL, name: String = "Share Source") throws -> (ModelContainer, Workspace) {
        let container = try makeContainer()
        let workspaceURL = root.appendingPathComponent("workspace-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: name, primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)
        return (container, workspace)
    }

    private static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Mutates a valid package's `workspace-share.json`, then refreshes the
    /// manifest digest and `checksums.json` so the tampered document is what
    /// validation actually sees (models a hand-edited-after-export package).
    private static func reseal(at packageURL: URL, _ mutate: (inout WorkspaceShareDocument) throws -> Void) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601

        let shareURL = packageURL.appendingPathComponent("workspace-share.json")
        var document = try decoder.decode(WorkspaceShareDocument.self, from: Data(contentsOf: shareURL))
        try mutate(&document)
        try encoder.encode(document).write(to: shareURL)

        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        var manifest = try decoder.decode(WorkspacePackageManifest.self, from: Data(contentsOf: manifestURL))
        manifest.sourceShareDigest = try PortablePackageSafeFileReader.digest(rootURL: packageURL, relativePath: "workspace-share.json")
        try encoder.encode(manifest).write(to: manifestURL)

        let paths = PortablePackageSafeFileReader.portableFilePaths(in: packageURL, intent: .explicitUserSelection)
            .filter { $0 != "checksums.json" }
        let checksums = try paths.map { path in
            WorkspacePackageChecksum(path: path, sha256: try PortablePackageSafeFileReader.digest(rootURL: packageURL, relativePath: path))
        }
        try encoder.encode(checksums).write(to: packageURL.appendingPathComponent("checksums.json"))
    }
}
