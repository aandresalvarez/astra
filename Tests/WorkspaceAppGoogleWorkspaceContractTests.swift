import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App — Google Workspace contracts")
struct WorkspaceAppGoogleWorkspaceContractTests {
    @Test("manifest validation accepts declared Google reads and gated writes")
    func manifestValidationAcceptsStableGoogleContracts() {
        #expect(WorkspaceAppManifestValidator.validate(Self.googleReadManifest()).isValid)
        #expect(WorkspaceAppManifestValidator.validate(Self.googleWriteManifest()).isValid)
    }

    @Test("manifest validation rejects raw Google MCP operations on stable contracts")
    func manifestValidationRejectsRawGoogleMCPOperations() {
        var manifest = Self.googleReadManifest()
        manifest.requirements[0].operations = ["gmail_get_thread"]
        manifest.sources[0].operation = "gmail_get_thread"

        let report = WorkspaceAppManifestValidator.validate(manifest)

        #expect(!report.isValid)
        #expect(report.blockers.contains {
            $0.path == "/requirements/0/operations/0" && $0.message.contains("not supported by contract 'gmail.thread.read'")
        })
    }

    @Test("astra.read maps a declared Google source through the app-scoped binding and fake resolver rows")
    func astraReadMapsDeclaredGoogleSourceThroughFakeResolver() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Google Workspace", primaryPath: root.path)
        let manifest = Self.googleReadManifest()
        let app = Self.app(for: manifest, workspace: workspace)
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            requirementID: "gmail",
            contract: "gmail.thread.read",
            operations: ["getThread"],
            optional: false,
            status: .mapped,
            implementationID: "fake-google-workspace-read",
            provider: "googleWorkspace",
            transport: .mcp
        )
        let recorder = GoogleReadRecorder()
        let resolver = WorkspaceAppSourceResolver(
            asyncCapabilityClient: FakeGoogleReadClient(
                rows: [["subject": .text("Quarterly planning"), "messageCount": .integer(3)]],
                recorder: recorder
            )
        )

        let resolved = WorkspaceAppDataBridge.resolveRead(
            .init(sourceId: "inbox_thread", record: ["threadId": .text("thread-1")], limit: 500),
            in: manifest
        )
        let bridgeInput = try #require(resolved?.input)
        let result = try await resolver.resolveCapabilityReadAsync(
            sourceID: bridgeInput.table ?? "",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppSourceResolutionInput(
                limit: bridgeInput.limit,
                parameters: bridgeInput.record
            )
        )

        #expect(result.rows == [["subject": .text("Quarterly planning"), "messageCount": .integer(3)]])
        #expect(result.implementationID == "fake-google-workspace-read")
        #expect(await recorder.last?.contract == "gmail.thread.read")
        #expect(await recorder.last?.operation == "getThread")
        #expect(await recorder.last?.parameters["threadId"] == .text("thread-1"))
        #expect(await recorder.last?.limit == WorkspaceAppDataBridge.maxConnectorReadLimit)
    }

    @Test("generated app JS gets only astra.read and cannot name raw tools or undeclared sources")
    func generatedAppJSGetsOnlyAstraRead() {
        let manifest = Self.googleReadManifest()
        let js = WorkspaceAppDataBridge.injectedScript.lowercased()

        #expect(js.contains("read: function"))
        #expect(!js.contains("gmail_get_thread"))
        #expect(!js.contains("google_workspace"))
        #expect(!js.contains("oauth"))
        #expect(!js.contains("token"))
        #expect(WorkspaceAppDataBridge.resolveRead(.init(sourceId: "inbox_thread", record: [:]), in: manifest) != nil)
        #expect(WorkspaceAppDataBridge.resolveRead(.init(sourceId: "other_thread", record: [:]), in: manifest) == nil)
    }

    @Test("connector rows redact credential-shaped fields before crossing into JS")
    func connectorRowsRedactCredentialFields() {
        let rows: [[String: WorkspaceAppStorageValue]] = [[
            "subject": .text("Planning"),
            "oauthToken": .text("ya29.secret"),
            "access_token": .text("secret"),
            "authorization": .text("Bearer secret")
        ]]

        let jsRows = WorkspaceAppDataBridge.jsConnectorRows(rows)

        #expect(jsRows.count == 1)
        #expect(jsRows[0]["subject"] as? String == "Planning")
        #expect(jsRows[0]["oauthToken"] == nil)
        #expect(jsRows[0]["access_token"] == nil)
        #expect(jsRows[0]["authorization"] == nil)
    }

    private static func googleReadManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "google-reader", name: "Google Reader"),
            requirements: [
                WorkspaceAppRequirement(
                    id: "gmail",
                    contract: "gmail.thread.read",
                    operations: ["getThread"],
                    providerHint: "googleWorkspace"
                )
            ],
            sources: [
                WorkspaceAppSource(
                    id: "inbox_thread",
                    requirementRef: "gmail",
                    operation: "getThread",
                    mode: "read"
                )
            ],
            actions: [
                WorkspaceAppActionSpec(id: "read_thread", type: "capability.read", sourceRef: "inbox_thread")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["gmail.thread.read"],
                defaultMode: .approvalRequired
            ),
            html: "<main></main><script>astra.read('inbox_thread', { params: { threadId: 'thread-1' } });</script>"
        )
    }

    private static func googleWriteManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "google-writer", name: "Google Writer"),
            requirements: [
                WorkspaceAppRequirement(
                    id: "docsWrite",
                    contract: "docs.document.write",
                    operations: ["replaceDocument"],
                    providerHint: "googleWorkspace"
                )
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "replace_doc",
                    type: "capability.write",
                    requirementRef: "docsWrite",
                    operation: "replaceDocument"
                )
            ],
            permissions: WorkspaceAppPermissions(
                externalWrites: ["docs.document.write"],
                defaultMode: .approvalRequired
            )
        )
    }

    private static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-google-contracts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func app(for manifest: WorkspaceAppManifest, workspace: Workspace) -> WorkspaceApp {
        WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
    }
}

private struct GoogleReadRequest: Sendable {
    var contract: String
    var operation: String
    var parameters: [String: WorkspaceAppStorageValue]
    var limit: Int
}

private actor GoogleReadRecorder {
    private(set) var last: GoogleReadRequest?

    func record(_ request: GoogleReadRequest) {
        last = request
    }
}

private struct FakeGoogleReadClient: WorkspaceAppAsyncCapabilitySourceClient {
    var rows: [[String: WorkspaceAppStorageValue]]
    var recorder: GoogleReadRecorder

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        await recorder.record(GoogleReadRequest(
            contract: binding.contract,
            operation: source.operation ?? requirement.operations.first ?? "",
            parameters: input.parameters,
            limit: input.limit
        ))
        return rows
    }
}
