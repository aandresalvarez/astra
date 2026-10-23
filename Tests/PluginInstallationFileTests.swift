import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Prepared Add and Create files", .serialized)
struct PluginInstallationFileTests {
    @Test("An invalid replacement icon cannot remove the previous installed definition")
    func invalidAssetLeavesPreviousCopy() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let before = try Data(contentsOf: env.disk.library.packageURL(for: env.package.id))
        var next = env.package
        next.version = "2.0.0"
        next.iconDescriptor = .asset("assets/missing.svg", fallbackSystemName: next.icon)
        next.sourceMetadata = .localLibrary(url: env.disk.root.appendingPathComponent("missing/capability.json"))
        #expect(throws: (any Error).self) { try env.installer.install(next, into: env.workspace, modelContext: env.context) }
        #expect(env.disk.library.installedPackage(id: next.id)?.version == "1.0.0")
        #expect(try Data(contentsOf: env.disk.library.packageURL(for: next.id)) == before)
        #expect(WorkspaceCapabilityActivation.activation(for: next.id, in: env.workspace) == nil)
    }

    @Test("A saved installation with a failed mirror keeps literal replay files")
    func committedInstallReplaysAfterReopen() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        var next = env.package
        next.version = "2.0.0"
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Blocked mirror".utf8).write(to: support)
        var operationID: UUID?
        do {
            _ = try env.installer.install(next, into: env.workspace, modelContext: env.context)
            Issue.record("The committed install must retain its recovery debt")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        let receipt = try #require(try PluginOperationCommit.read(id, container: env.disk.container))
        #expect(receipt.manifestDigest != nil)
        let journal = PluginFileOperationJournal(library: env.disk.library, approvals: CapabilityApprovalStore())
        #expect(try journal.pendingIDs() == [id])
        // A partial/lost file write must recover from literal prepared bytes.
        try Data("Interrupted definition".utf8).write(to: env.disk.library.packageURL(for: next.id))
        try FileManager.default.removeItem(at: support)
        let reopened = try env.disk.reopen()
        let replay = PluginFileOperationRecovery(journal: journal).resumePending(modelContext: reopened.mainContext)
        #expect(replay.completed == 1 && replay.deferred == 0)
        #expect(env.disk.library.installedPackage(id: next.id)?.version == "2.0.0")
        #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
    }

    @Test("Create without enabling uses a file receipt and never saves an unrelated editor")
    func installOnlyCreateHasIndependentCommit() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        env.workspace.name = "Unsaved editor"
        let result = try CapabilityPackageCreationService(library: env.disk.library).create(env.package,
            enableHere: false, sourceURL: nil, workspace: env.workspace, modelContext: env.context)
        #expect(result.installationResult == nil)
        let reopened = try env.disk.reopen()
        #expect(try reopened.mainContext.fetch(FetchDescriptor<Workspace>()).first?.name == "Add commit")
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).isEmpty)
        let receipts = try reopened.mainContext.fetch(FetchDescriptor<PluginOperationReceipt>())
        #expect(receipts.contains { $0.kindRawValue == PluginOperationReceipt.Kind.add.rawValue && $0.manifestDigest != nil && $0.completedAt != nil })
        #expect(env.disk.library.installedPackage(id: env.package.id) != nil)
    }

    @Test("Add and Create approve the actual icon bytes at their preserved source locator", arguments: [false, true])
    func iconLocatorSurvivesCanonicalReview(create: Bool) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let root = env.disk.root.appendingPathComponent("Authored")
        let asset = root.appendingPathComponent("assets/icon.svg")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path d="M0 0h8v8H0z"/></svg>"#.utf8).write(to: asset)
        var package = env.package
        package.governance = .localDraft()
        package.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: package.icon)
        package.sourceMetadata = .localLibrary(url: root.appendingPathComponent("capability.json"))
        let approvals = CapabilityApprovalStore(directory: env.disk.root.appendingPathComponent("Approvals"))
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: env.workspace, approvalRecords: [])
        if create {
            _ = try CapabilityPackageCreationService(library: env.disk.library, approvalStore: approvals).create(package,
                enableHere: true, sourceURL: nil, workspace: env.workspace, modelContext: env.context, policyContext: policy)
        } else {
            _ = try CapabilityCatalogActionService(library: env.disk.library).add(package,
                workspace: env.workspace, modelContext: env.context, policyContext: policy, approvalStore: approvals, traceID: "icon-add")
        }
        let installed = try #require(env.disk.library.installedPackage(id: package.id))
        #expect(approvals.record(for: installed)?.status == .approved)
        #expect(CapabilityCatalogPolicy.decision(for: installed, context: .currentUser(workspace: env.workspace,
            approvalRecords: approvals.records())).canEnable)
    }

    @Test("An interrupted replacement with refused rollback is recoverable without a domain commit")
    func interruptedReplacementRetainsRollbackFiles() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let files = InterruptedInstallationFiles(target: env.disk.library.packageURL(for: env.package.id))
        let library = CapabilityLibrary(directory: env.disk.library.directory, fileManager: files)
        var next = env.package
        next.version = "2.0.0"
        #expect(throws: PluginOperationProblem.self) {
            try CapabilityInstaller(library: library).install(next, into: env.workspace, modelContext: env.context)
        }
        let journal = PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore())
        let id = try #require(try journal.pendingIDs().first)
        #expect(try PluginOperationCommit.read(id, container: env.disk.container) == nil)
        #expect(WorkspaceCapabilityActivation.activation(for: next.id, in: env.workspace) == nil)
        files.refusesRollback = false
        let reopened = try env.disk.reopen()
        let replay = PluginFileOperationRecovery(journal: journal).resumePending(modelContext: reopened.mainContext)
        #expect(replay.completed == 1 && replay.deferred == 0)
        #expect(library.installedPackage(id: next.id)?.version == "1.0.0")
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).isEmpty)
    }
}

private final class InterruptedInstallationFiles: FileManager {
    let target: URL
    var refusesRollback = true
    private var interrupted = false
    init(target: URL) { self.target = target; super.init() }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        if !interrupted, dstURL.standardizedFileURL == target.standardizedFileURL {
            interrupted = true
            throw CocoaError(.fileWriteUnknown)
        }
    }
    override func removeItem(at url: URL) throws {
        if interrupted, refusesRollback, url.standardizedFileURL == target.standardizedFileURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
