import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace Packages")
struct WorkspacePackageTests {

    // MARK: - Round trip

    @MainActor
    @Test("exported configuration package round-trips through validation")
    func exportedPackageRoundTripsThroughValidation() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        workspace.instructions = "Prefer concise summaries."

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        #expect(result.manifest.workspaceName == workspace.name)
        #expect(result.manifest.exportProfile == .configurationOnly)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        #expect(report.shareDocument?.instructions == "Prefer concise summaries.")
    }

    @MainActor
    @Test("exported package excludes task history and workspace app run data")
    func exportedPackageExcludesHistory() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let task = AgentTask(title: "Investigate flaky test", goal: "Root-cause it", workspace: workspace)
        container.mainContext.insert(task)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        // The slim share DTO has no slot for task history or workspace-app run
        // data at all, so the guarantee is now structural: those keys never
        // appear in the on-disk share document.
        let shareText = String(
            decoding: try Data(contentsOf: destination.appendingPathComponent("workspace-share.json")),
            as: UTF8.self
        )
        #expect(!shareText.contains("\"tasks\""))
        #expect(!shareText.contains("\"workspaceApps\""))
    }

    // MARK: - Capability governance

    @MainActor
    @Test("exported package clamps custom capability governance to local draft")
    func exportedPackageClampsCapabilityGovernance() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        // Starts already-approved locally, so a passing test proves the
        // exporter actively clamps it down rather than happening to match a
        // default.
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .builtInApproved()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        #expect(result.manifest.capabilityEntries.map(\.packageID) == ["local.tool"])
        let embeddedData = try Data(contentsOf: destination.appendingPathComponent("capabilities/local.tool.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let embedded = try decoder.decode(PluginPackage.self, from: embeddedData)
        #expect(embedded.governance.approvalStatus == .draft)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
    }

    // Deliberately no "excludes built-in capabilities" test: CapabilityLibrary's
    // read path (decodeInstalledPackage) re-derives trust from
    // CapabilityLibrary.trustedBuiltInPackageIDs — a real, compiled catalog —
    // not from whatever sourceMetadata a caller writes to disk, so a fixture
    // can't fake a built-in ID without coupling the test to production
    // catalog contents. The exporter's exclusion branch is simple, directly
    // reviewable code; the "embeds and clamps a non-built-in capability" test
    // above exercises the other side of the same condition.

    // MARK: - Exporter self-verification

    @MainActor
    @Test("exporter rejects a workspace whose instructions contain credential-like content")
    func exporterRejectsCredentialLikeContent() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        // An actual credential assignment (key + delimiter + value), not merely
        // prose mentioning "api_key" — the scan is assignment-shaped now.
        workspace.instructions = "Use api_key=sk-live-supersecret123 for local runs."

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        #expect(throws: WorkspacePackageExportError.self) {
            _ = try WorkspacePackageExporter().exportConfigurationPackage(
                workspace: workspace,
                modelContext: container.mainContext,
                to: destination
            )
        }
        // Self-verification failure must not leave a staged or published
        // artifact behind for the caller to accidentally pick up.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Validation

    @MainActor
    @Test("package validation blocks tampered checksums")
    func validationBlocksTamperedChecksums() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let configURL = destination.appendingPathComponent("workspace-share.json")
        var data = try Data(contentsOf: configURL)
        data.append(contentsOf: "\n// tampered".utf8)
        try data.write(to: configURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("Checksum does not match") })
    }

    @MainActor
    @Test("package validation rejects package below minimum ASTRA version")
    func validationRejectsOldMinimumVersion() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let manifestURL = destination.appendingPathComponent("manifest.json")
        var manifest = try Self.decodeManifest(at: manifestURL)
        manifest.minimumASTRAVersion = "999.0.0"
        try Self.encodeManifest(manifest, to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("requires ASTRA 999.0.0 or later") })
    }

    @MainActor
    @Test("package validation rejects unlisted files not present in checksums.json")
    func validationRejectsUnlistedFiles() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        try Data("stowaway".utf8).write(to: destination.appendingPathComponent("extra.txt"))

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("not listed in checksums.json") })
    }

    @MainActor
    @Test("package validation rejects embedded capability with elevated governance")
    func validationRejectsElevatedEmbeddedGovernance() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let capabilityURL = destination.appendingPathComponent("capabilities/local.tool.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var capability = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        capability.governance.approvalStatus = .approved
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(capability).write(to: capabilityURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("must land as a local draft") })
    }

    // MARK: - Embedded apps

    @MainActor
    @Test("exported package embeds workspace apps as validated .astra-app bundles")
    func exportedPackageEmbedsWorkspaceApps() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)

        // Plant a real app on the workspace via the already-tested .astra-app
        // import path, rather than hand-building WorkspaceApp + on-disk
        // manifest bookkeeping ourselves.
        let sourcePackageURL = root.appendingPathComponent("source.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.minimalAppManifest(id: "notes", name: "Notes"),
            to: sourcePackageURL
        )
        _ = try WorkspaceAppPackageService().importPackage(
            at: sourcePackageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        #expect(result.manifest.appEntries.count == 1)
        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        let entry = try #require(result.manifest.appEntries.first)
        let appReport = try #require(report.appReports[entry.logicalID])
        #expect(appReport.canInstall)
    }

    // MARK: - Machine-local state stripping

    @MainActor
    @Test("exported package strips the machine-local execution environment")
    func exportedPackageStripsExecutionEnvironment() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        workspace.activeExecutionEnvironmentJSON = "{\"kind\":\"docker\",\"sourcePath\":\"/opt/only-on-sender\"}"

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        // The share DTO cannot express an execution environment at all, so the
        // sender-only sentinel path never reaches the on-disk share document.
        let shareText = String(
            decoding: try Data(contentsOf: destination.appendingPathComponent("workspace-share.json")),
            as: UTF8.self
        )
        #expect(!shareText.contains("/opt/only-on-sender"))
    }

    @MainActor
    @Test("exported package blanks SSH key paths but flags them for local setup")
    func exportedPackageBlanksSSHKeyPaths() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        SSHConnectionManager.save(
            [SSHConnection(name: "prod", host: "prod.example.com", user: "deploy", keyPath: "/Users/alice/.ssh/prod_key")],
            workspacePath: workspace.primaryPath
        )

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // The sender's absolute private-key path never leaves the machine...
        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        #expect(report.shareDocument?.sshConnections.count == 1)
        // The share DTO has no key-path slot, so the sender's absolute key path
        // never reaches the on-disk share document.
        let shareText = String(
            decoding: try Data(contentsOf: destination.appendingPathComponent("workspace-share.json")),
            as: UTF8.self
        )
        #expect(!shareText.contains("/Users/alice/.ssh/prod_key"))
        // ...but the connection is still flagged so the recipient knows to
        // re-point a key locally.
        #expect(result.manifest.sshConnectionsRequiringLocalKeys == ["prod"])
    }

    @MainActor
    @Test("exported package strips schedule run history and routine paths")
    func exportedPackageStripsScheduleHistoryAndPaths() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)

        let schedule = TaskSchedule(name: "Nightly", goal: "Summarize new issues", workspace: workspace)
        schedule.routinePaths = ["/Users/alice/only-on-sender/repo"]
        schedule.runResultsJSON = "[{\"summary\":\"prior sender-machine output\"}]"
        schedule.conversationContext = "prior conversation snapshot"
        schedule.sourceTaskID = UUID()
        schedule.lastFiredAt = Date(timeIntervalSince1970: 1_700_000_000)
        schedule.fireCount = 7
        container.mainContext.insert(schedule)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        // The ShareSchedule DTO carries only the recurring definition; run
        // history, timing state, and sender-machine paths have no slot to travel
        // in — the guarantee is structural, so assert on the raw bytes.
        let shareText = String(
            decoding: try Data(contentsOf: destination.appendingPathComponent("workspace-share.json")),
            as: UTF8.self
        )
        #expect(!shareText.contains("only-on-sender"))
        #expect(!shareText.contains("prior sender-machine output"))
        #expect(!shareText.contains("prior conversation snapshot"))
        // ...but the routine's definition still does.
        let exported = try #require(report.shareDocument?.schedules.first)
        #expect(exported.name == "Nightly")
        #expect(exported.goal == "Summarize new issues")
    }

    @MainActor
    @Test("package validation rejects a capability whose embedded ID differs from its manifest entry")
    func validationRejectsMismatchedCapabilityID() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // The manifest entry still declares "local.tool", but the embedded file
        // now carries a different package id — a package advertising an innocuous
        // entry while installing (or overwriting) a different id.
        let capabilityURL = destination.appendingPathComponent("capabilities/local.tool.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var capability = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        capability.id = "com.acme.github"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(capability).write(to: capabilityURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("does not match its manifest entry ID") })
    }

    @MainActor
    @Test("package validation rejects an embedded capability whose name differs from its manifest entry")
    func validationRejectsMismatchedCapabilityName() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // The review shows the manifest entry's displayName, but the coordinator
        // installs the decoded package's own name — a benign display over a
        // different embedded name must be rejected.
        let capabilityURL = destination.appendingPathComponent("capabilities/local.tool.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var capability = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        capability.name = "Totally Different Capability"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(capability).write(to: capabilityURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("does not match its manifest entry display name") })
    }

    @MainActor
    @Test("package validation rejects an embedded capability using a trusted built-in ID")
    func validationRejectsEmbeddedBuiltInCapabilityID() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // A share that embeds a draft payload under a curated built-in ID would,
        // if the built-in's library file is absent, install and then get the
        // compiled approved governance applied — auto-approving attacker content.
        let builtInID = try #require(CapabilityLibrary.trustedBuiltInPackageIDs.first)
        let capabilityURL = destination.appendingPathComponent("capabilities/local.tool.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var capability = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        capability.id = builtInID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(capability).write(to: capabilityURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("built-in ID") })
    }

    @MainActor
    @Test("package validation rejects an embedded app whose ID differs from its manifest entry")
    func validationRejectsMismatchedAppID() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let sourcePackageURL = root.appendingPathComponent("source.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.minimalAppManifest(id: "notes", name: "Notes"),
            to: sourcePackageURL
        )
        _ = try WorkspaceAppPackageService().importPackage(
            at: sourcePackageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // The embedded bundle is still a valid "notes" app, but the outer entry
        // now claims a different logical ID than the bundle actually installs.
        let manifestURL = destination.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(WorkspacePackageManifest.self, from: Data(contentsOf: manifestURL))
        manifest.appEntries = manifest.appEntries.map { entry in
            var mutated = entry
            mutated.logicalID = "spoofed"
            return mutated
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("does not match its manifest entry ID") })
    }

    @MainActor
    @Test("package validation rejects duplicate embedded app logical IDs")
    func validationRejectsDuplicateAppLogicalIDs() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let sourcePackageURL = root.appendingPathComponent("source.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.minimalAppManifest(id: "notes", name: "Notes"),
            to: sourcePackageURL
        )
        _ = try WorkspaceAppPackageService().importPackage(
            at: sourcePackageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // Two entries reusing one logical ID would collapse to a single keyed
        // report, so a safe bundle could mask a permission-sensitive one while
        // both import (createApp suffixes the collided ID).
        let manifestURL = destination.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(WorkspacePackageManifest.self, from: Data(contentsOf: manifestURL))
        if let first = manifest.appEntries.first {
            manifest.appEntries = [first, first]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.lowercased().contains("duplicate app") })
    }

    @MainActor
    @Test("exported package downgrades an asset-icon capability to its fallback symbol")
    func exportedPackageDowngradesAssetIcon() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)

        // A capability whose icon is an on-disk asset: CapabilityLibrary.install
        // would copy it from an asset root the draft clamp strips, so import
        // would throw and roll back the whole workspace. The exporter must
        // downgrade the icon to the descriptor's fallback symbol.
        let assetRoot = root.appendingPathComponent("asset-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetRoot.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("png".utf8).write(to: assetRoot.appendingPathComponent("assets/icon.png"))
        var capability = Self.makeCapability(id: "local.tool", governance: .localDraft())
        capability.iconDescriptor = .asset("assets/icon.png", fallbackSystemName: "puzzlepiece.extension")

        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(CapabilityPackageSource(package: capability, manifestURL: nil, assetRootURL: assetRoot))
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let embedded = try decoder.decode(
            PluginPackage.self,
            from: Data(contentsOf: destination.appendingPathComponent("capabilities/local.tool.json"))
        )
        #expect(embedded.iconDescriptor.kind == .systemSymbol)
        #expect(embedded.iconDescriptor.value == "puzzlepiece.extension")
        #expect(WorkspacePackageService().validatePackage(at: destination).canInstall)
    }

    // MARK: - Embedded app containment / version gate

    @MainActor
    @Test("package validation rejects an embedded app bundle path outside the package")
    func validationRejectsAppBundlePathTraversal() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let sourceApp = root.appendingPathComponent("source.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.minimalAppManifest(id: "notes", name: "Notes"),
            to: sourceApp
        )
        _ = try WorkspaceAppPackageService().importPackage(at: sourceApp, into: workspace, modelContext: container.mainContext)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // Point the app bundle outside the package: an untrusted manifest whose
        // checksums cover only its own files must not be able to validate/import
        // a bundle escaping the `.astra-share` directory.
        let manifestURL = destination.appendingPathComponent("manifest.json")
        var manifest = try Self.decodeManifest(at: manifestURL)
        manifest.appEntries = manifest.appEntries.map { entry in
            var tampered = entry
            tampered.relativeBundlePath = "../escape.astra-app"
            return tampered
        }
        try Self.encodeManifest(manifest, to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("must stay inside the package") })
    }

    @MainActor
    @Test("package validation rejects a malformed minimum ASTRA version")
    func validationRejectsMalformedVersion() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let manifestURL = destination.appendingPathComponent("manifest.json")
        var manifest = try Self.decodeManifest(at: manifestURL)
        manifest.minimumASTRAVersion = "not-a-version"
        try Self.encodeManifest(manifest, to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("is not a valid version string") })
    }

    @MainActor
    @Test("package validation rejects duplicate embedded capability entry IDs")
    func validationRejectsDuplicateCapabilityEntryIDs() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // Duplicate the single capability entry.
        let manifestURL = destination.appendingPathComponent("manifest.json")
        var manifest = try Self.decodeManifest(at: manifestURL)
        if let first = manifest.capabilityEntries.first {
            manifest.capabilityEntries = [first, first]
        }
        try Self.encodeManifest(manifest, to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.lowercased().contains("duplicate capability") })
    }

    @MainActor
    @Test("exported embedded capability blanks secret-keyed skill defaults; validation rejects a tampered one")
    func exportBlanksEmbeddedCapabilitySecretDefaults() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        var capability = Self.makeCapability(id: "secret.cap", governance: .localDraft())
        capability.skills = [PluginSkill(
            name: "Secret Skill", icon: "gear", description: "d",
            allowedTools: [], disallowedTools: [], customTools: [], behaviorInstructions: "",
            environmentKeys: ["API_TOKEN", "REGION"],
            environmentValues: ["hunter2-embedded-secret", "us-west"]
        )]
        try capabilityLibrary.install(capability, sourceMetadata: .localLibrary())
        workspace.enabledCapabilityIDs = ["secret.cap"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // The secret value must not appear in the embedded capability JSON.
        let capabilityURL = destination.appendingPathComponent("capabilities/secret.cap.json")
        let text = try String(contentsOf: capabilityURL, encoding: .utf8)
        #expect(!text.contains("hunter2-embedded-secret"))
        #expect(text.contains("us-west"))
        #expect(WorkspacePackageService().validatePackage(at: destination).canInstall)

        // A hand-tampered package that re-plants the secret is rejected.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var tampered = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        tampered.skills[0].environmentValues[0] = "hunter2-embedded-secret"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tampered).write(to: capabilityURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("secret environment value") })
    }

    @MainActor
    @Test("exported embedded capability strips credential-carrying connector URLs; validation rejects a tampered one")
    func exportStripsEmbeddedCapabilityConnectorCredentials() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        var capability = Self.makeCapability(id: "conn.cap", governance: .localDraft())
        capability.connectors = [PluginConnector(
            name: "API", serviceType: "custom", icon: "bolt", description: "d",
            baseURL: "https://api.example.com/v1?api_token=supersecret123", authMethod: "none",
            credentialHints: [], configHints: [], notes: ""
        )]
        try capabilityLibrary.install(capability, sourceMetadata: .localLibrary())
        workspace.enabledCapabilityIDs = ["conn.cap"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace, modelContext: container.mainContext, to: destination
        )
        let capabilityURL = destination.appendingPathComponent("capabilities/conn.cap.json")
        let text = try String(contentsOf: capabilityURL, encoding: .utf8)
        #expect(!text.contains("supersecret123"))
        #expect(WorkspacePackageService().validatePackage(at: destination).canInstall)

        // Re-plant the credential in the embedded capability connector URL.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var tampered = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        tampered.connectors[0].baseURL = "https://api.example.com/v1?api_token=supersecret123"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tampered).write(to: capabilityURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("carries a credential") })
    }

    @MainActor
    @Test("exported embedded capability strips MCP server URL credentials; validation rejects tampered MCP creds/paths")
    func exportSanitizesEmbeddedCapabilityMCPServers() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        var capability = Self.makeCapability(id: "mcp.cap", governance: .localDraft())
        capability.mcpServers = [PluginMCPServer(
            id: "srv", displayName: "Srv", transport: .http,
            url: URL(string: "https://api.example.com/mcp?api_token=supersecret123")
        )]
        try capabilityLibrary.install(capability, sourceMetadata: .localLibrary())
        workspace.enabledCapabilityIDs = ["mcp.cap"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace, modelContext: container.mainContext, to: destination
        )
        let capabilityURL = destination.appendingPathComponent("capabilities/mcp.cap.json")
        let text = try String(contentsOf: capabilityURL, encoding: .utf8)
        #expect(!text.contains("supersecret123"))
        #expect(WorkspacePackageService().validatePackage(at: destination).canInstall)

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601

        // Re-plant a credential in the MCP url → rejected.
        var tamperedURL = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        tamperedURL.mcpServers[0].url = URL(string: "https://user:tok@api.example.com/mcp")
        try encoder.encode(tamperedURL).write(to: capabilityURL)
        var report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("MCP server") && $0.message.contains("credential") })

        // A stdio command with an absolute machine path → rejected.
        var tamperedPath = tamperedURL
        tamperedPath.mcpServers = [PluginMCPServer(
            id: "srv", displayName: "Srv", transport: .stdio,
            command: "/Users/alice/.local/bin/my-mcp", arguments: ["--token", "hunter2secret"]
        )]
        try encoder.encode(tamperedPath).write(to: capabilityURL)
        report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("MCP server") && $0.message.contains("machine path") })
    }

    @MainActor
    @Test("exported embedded capability blanks secret-keyed template defaults; validation rejects a tampered/malformed one")
    func exportBlanksEmbeddedCapabilityTemplateSecretDefaults() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        var capability = Self.makeCapability(id: "tmpl.cap", governance: .localDraft())
        capability.templates = [PluginTemplate(
            name: "Deploy", icon: "gear", description: "d", mainGoal: "ship",
            beforeGoal: "", afterGoal: "", mainBudget: 0, beforeBudget: 0, afterBudget: 0,
            variablesJSON: #"[{"id":"00000000-0000-0000-0000-000000000001","name":"API_TOKEN","label":"Token","defaultValue":"hunter2-tmpl-secret","isRequired":true},{"id":"00000000-0000-0000-0000-000000000002","name":"REGION","label":"Region","defaultValue":"us-west","isRequired":false}]"#,
            passContextToMain: false, passContextToAfter: false
        )]
        try capabilityLibrary.install(capability, sourceMetadata: .localLibrary())
        workspace.enabledCapabilityIDs = ["tmpl.cap"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace, modelContext: container.mainContext, to: destination
        )
        let capabilityURL = destination.appendingPathComponent("capabilities/tmpl.cap.json")
        let text = try String(contentsOf: capabilityURL, encoding: .utf8)
        #expect(!text.contains("hunter2-tmpl-secret"))
        #expect(text.contains("us-west"))
        #expect(WorkspacePackageService().validatePackage(at: destination).canInstall)

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601

        // Re-plant the secret default → rejected.
        var tampered = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        tampered.templates[0].variablesJSON = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"API_TOKEN","label":"Token","defaultValue":"hunter2-tmpl-secret","isRequired":true}]"#
        try encoder.encode(tampered).write(to: capabilityURL)
        var report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("secret-like name") })

        // A malformed variables blob (bypasses the secret scrub) → rejected.
        tampered.templates[0].variablesJSON = "{not valid variables json"
        try encoder.encode(tampered).write(to: capabilityURL)
        report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("must decode as an array of template variables") })
    }

    @MainActor
    @Test("validation scans embedded capability CLI prerequisites for credentials and machine paths")
    func validationScansEmbeddedCapabilityPrerequisites() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        let capability = Self.makeCapability(id: "prereq.cap", governance: .localDraft())
        try capabilityLibrary.install(capability, sourceMetadata: .localLibrary())
        workspace.enabledCapabilityIDs = ["prereq.cap"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace, modelContext: container.mainContext, to: destination
        )
        let capabilityURL = destination.appendingPathComponent("capabilities/prereq.cap.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601

        // A credential pasted into an install hint → rejected.
        var tampered = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        tampered.prerequisites = [CLIPrerequisite(
            binary: "mytool", displayName: "My Tool", purpose: "does things",
            installHint: "Run API_TOKEN=supersecret123 mytool install"
        )]
        try encoder.encode(tampered).write(to: capabilityURL)
        var report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("credential material") })

        // An absolute machine path in the auth hint → rejected.
        tampered.prerequisites = [CLIPrerequisite(
            binary: "mytool", displayName: "My Tool", purpose: "does things",
            installHint: "brew install mytool", authHint: "Point it at /Users/alice/.config/mytool"
        )]
        try encoder.encode(tampered).write(to: capabilityURL)
        report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("absolute local path") })

        // Credentials embedded in the install URL → rejected.
        tampered.prerequisites = [CLIPrerequisite(
            binary: "mytool", displayName: "My Tool", purpose: "does things",
            installURL: URL(string: "https://user:tok@example.com/install"), installHint: "brew install mytool"
        )]
        try encoder.encode(tampered).write(to: capabilityURL)
        report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("prerequisite install URL must not embed credentials") })
    }

    @MainActor
    @Test("validation stops enumerating embedded entries once the manifest inventory limit is exceeded")
    func validationSkipsEntryLoopsOverInventoryLimit() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace, modelContext: container.mainContext, to: destination
        )

        // Rewrite manifest.json with 1001 app entries all pointing at the same
        // (absent) bundle path, then refresh checksums so the tampered manifest is
        // what validation reads. A per-entry loop would emit a "missing bundle"
        // blocker 1001 times (and re-stat that path each time); the guard should
        // emit only the cardinality blocker.
        let manifestURL = destination.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var manifest = try decoder.decode(WorkspacePackageManifest.self, from: Data(contentsOf: manifestURL))
        manifest.appEntries = (0..<1001).map {
            WorkspacePackageAppEntry(
                logicalID: "app-\($0)", displayName: "App \($0)",
                relativeBundlePath: "apps/missing.astra-app", packageDigest: "deadbeef"
            )
        }
        try encoder.encode(manifest).write(to: manifestURL)
        let paths = PortablePackageSafeFileReader.portableFilePaths(in: destination, intent: .explicitUserSelection)
            .filter { $0 != "checksums.json" }
        let checksums = try paths.map {
            WorkspacePackageChecksum(path: $0, sha256: try PortablePackageSafeFileReader.digest(rootURL: destination, relativePath: $0))
        }
        try encoder.encode(checksums).write(to: destination.appendingPathComponent("checksums.json"))

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("exceeding the 1000 limit") })
        // The per-entry loop was skipped: no embedded-app reports were produced and
        // the 1001 entries did not each contribute a per-bundle blocker.
        #expect(report.appReports.isEmpty)
        #expect(report.blockers.count < 10)
    }

    @MainActor
    @Test("validation rejects duplicate embedded bundle paths across app entries")
    func validationRejectsDuplicateBundlePaths() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace, modelContext: container.mainContext, to: destination
        )
        // Two distinct logical IDs pointing at the SAME bundle path — a
        // repeated-read amplification vector, and rejected outright.
        let manifestURL = destination.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var manifest = try decoder.decode(WorkspacePackageManifest.self, from: Data(contentsOf: manifestURL))
        manifest.appEntries = [
            WorkspacePackageAppEntry(logicalID: "a", displayName: "A", relativeBundlePath: "apps/shared.astra-app", packageDigest: "d"),
            WorkspacePackageAppEntry(logicalID: "b", displayName: "B", relativeBundlePath: "apps/shared.astra-app", packageDigest: "d")
        ]
        try encoder.encode(manifest).write(to: manifestURL)
        let paths = PortablePackageSafeFileReader.portableFilePaths(in: destination, intent: .explicitUserSelection)
            .filter { $0 != "checksums.json" }
        let checksums = try paths.map {
            WorkspacePackageChecksum(path: $0, sha256: try PortablePackageSafeFileReader.digest(rootURL: destination, relativePath: $0))
        }
        try encoder.encode(checksums).write(to: destination.appendingPathComponent("checksums.json"))

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("Duplicate") && $0.message.contains("app bundle paths") })
    }

    @MainActor
    @Test("validation scans nested MCP control-plane metadata of an embedded capability")
    func validationScansEmbeddedCapabilityMCPControlPlane() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        let capability = Self.makeCapability(id: "cp.cap", governance: .localDraft())
        try capabilityLibrary.install(capability, sourceMetadata: .localLibrary())
        workspace.enabledCapabilityIDs = ["cp.cap"]
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace, modelContext: container.mainContext, to: destination
        )
        let capabilityURL = destination.appendingPathComponent("capabilities/cp.cap.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601

        // A credential pasted into a control-plane secretRef purpose blurb.
        var tampered = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        tampered.mcpServers = [PluginMCPServer(
            id: "srv", displayName: "Srv", transport: .stdio, command: "mytool",
            controlPlane: MCPControlPlaneMetadata(
                secretRefs: [MCPSecretRef(id: "tok", purpose: "Use API_TOKEN=supersecret123 for auth")]
            )
        )]
        try encoder.encode(tampered).write(to: capabilityURL)
        var report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("control-plane/registry metadata contains a credential") })

        // An absolute machine path in the same nested prose.
        tampered.mcpServers = [PluginMCPServer(
            id: "srv", displayName: "Srv", transport: .stdio, command: "mytool",
            controlPlane: MCPControlPlaneMetadata(
                secretRefs: [MCPSecretRef(id: "tok", purpose: "Key lives at /Users/alice/.secrets/token")]
            )
        )]
        try encoder.encode(tampered).write(to: capabilityURL)
        report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("control-plane/registry metadata contains an absolute machine path") })
    }

    // MARK: - Fixtures

    @MainActor
    private static func makeWorkspace(root: URL, name: String = "Package Export") throws -> (ModelContainer, Workspace) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: name, primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)
        return (container, workspace)
    }

    private static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func minimalAppManifest(id: String, name: String) -> WorkspaceAppManifest {
        WorkspaceAppManifest(app: WorkspaceAppManifestMetadata(
            id: id,
            name: name,
            icon: "app",
            description: "Fixture app.",
            tags: [],
            archetypes: []
        ))
    }

    private static func makeCapability(id: String, governance: CapabilityGovernance) -> PluginPackage {
        PluginPackage(
            id: id,
            name: "Fixture Capability",
            icon: "puzzlepiece.extension",
            description: "Fixture capability for package export tests.",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: governance
        )
    }

    private static func decodeManifest(at url: URL) throws -> WorkspacePackageManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspacePackageManifest.self, from: Data(contentsOf: url))
    }

    private static func encodeManifest(_ manifest: WorkspacePackageManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url)
    }
}
