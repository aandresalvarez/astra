import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Source Resolver")
struct WorkspaceAppSourceResolverTests {
    @Test("resolver reads declared app storage sources")
    func resolverReadsDeclaredAppStorageSources() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Storage Sources", primaryPath: root.path)
        let manifest = Self.storageManifest()
        let app = Self.app(for: manifest, workspace: workspace)
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        let storage = WorkspaceAppStorageService()
        try storage.applySchema(try #require(manifest.storage), databaseURL: databaseURL)
        try storage.insertRecord(
            ["id": .text("item-1"), "name": .text("Apples"), "quantity": .integer(6)],
            into: "items",
            databaseURL: databaseURL
        )

        let result = try WorkspaceAppSourceResolver().resolve(
            sourceID: "inventory",
            app: app,
            workspace: workspace,
            manifest: manifest
        )

        #expect(result.sourceID == "inventory")
        #expect(result.rows.count == 1)
        #expect(result.rows[0]["name"] == .text("Apples"))
        #expect(result.rows[0]["quantity"] == .integer(6))
        #expect(result.implementationID == "app-storage-native")
        #expect(result.provider == "astra")
        #expect(result.outputSummary.contains("app storage table 'items'"))
    }

    @Test("resolver reads mocked capability contract sources through mapped bindings")
    func resolverReadsMockedCapabilitySourcesThroughBindings() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        let manifest = Self.reconciliationManifest()
        let app = Self.app(for: manifest, workspace: workspace)
        let bindings = [
            WorkspaceAppDependencyBinding(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                requirementID: "sourceWarehouse",
                contract: "tabularQuery.read",
                operations: ["runReadOnlyQuery"],
                optional: false,
                status: .mapped,
                implementationID: "bigquery-read-task-backed",
                provider: "bigQuery",
                transport: .taskBacked
            ),
            WorkspaceAppDependencyBinding(
                workspaceID: workspace.id,
                appID: app.id,
                appLogicalID: app.logicalID,
                requirementID: "targetRecords",
                contract: "recordProject.read",
                operations: ["readRecords"],
                optional: false,
                status: .mapped,
                implementationID: "redcap-read-task-backed",
                provider: "redcap",
                transport: .taskBacked
            )
        ]
        let resolver = WorkspaceAppSourceResolver(
            capabilityClient: MockCapabilitySourceClient(rowsBySourceID: [
                "warehouse_latest": [
                    ["participant_id": .text("P-001"), "mrn": .text("1001")]
                ],
                "redcap_records": [
                    ["participant_id": .text("P-002"), "record_id": .text("2")]
                ]
            ])
        )

        let warehouse = try resolver.resolve(
            sourceID: "warehouse_latest",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: bindings
        )
        let redcap = try resolver.resolve(
            sourceID: "redcap_records",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: bindings
        )

        #expect(warehouse.rows == [["participant_id": .text("P-001"), "mrn": .text("1001")]])
        #expect(warehouse.requirementID == "sourceWarehouse")
        #expect(warehouse.implementationID == "bigquery-read-task-backed")
        #expect(warehouse.provider == "bigQuery")
        #expect(redcap.rows == [["participant_id": .text("P-002"), "record_id": .text("2")]])
        #expect(redcap.requirementID == "targetRecords")
        #expect(redcap.implementationID == "redcap-read-task-backed")
        #expect(redcap.provider == "redcap")
    }

    @Test("async resolver reads BigQuery table sources through native query client")
    func asyncResolverReadsBigQueryTableSourcesThroughNativeQueryClient() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        var manifest = Self.reconciliationManifest()
        manifest.sources[0].projectRef = "clinical-prod"
        let app = Self.app(for: manifest, workspace: workspace)
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            requirementID: "sourceWarehouse",
            contract: "tabularQuery.read",
            operations: ["runReadOnlyQuery"],
            optional: false,
            status: .mapped,
            implementationID: "bigquery-read-native",
            provider: "bigQuery",
            transport: .native
        )
        let runner = MockWorkspaceAppDatabaseQueryRunner(result: QueryExecutionResult(
            columns: [
                QueryResultColumn(name: "participant_id", type: "STRING"),
                QueryResultColumn(name: "mrn", type: "STRING")
            ],
            rows: [["P-001", "1001"]],
            rowCount: 1,
            bytesProcessed: 512,
            elapsedMilliseconds: 25,
            jobID: "job-1",
            message: "Query completed."
        ))
        let resolver = WorkspaceAppSourceResolver(
            asyncCapabilityClient: WorkspaceAppNativeAsyncCapabilitySourceClient(queryRunner: runner)
        )

        let result = try await resolver.resolveAsync(
            sourceID: "warehouse_latest",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppSourceResolutionInput(limit: 25)
        )

        #expect(result.rows == [["participant_id": .text("P-001"), "mrn": .text("1001")]])
        #expect(result.implementationID == "bigquery-read-native")
        #expect(result.provider == "bigQuery")
        #expect(await runner.requests.first?.sql == "SELECT * FROM `clinical-prod.clinical.enrollment_candidates` LIMIT 25")
        #expect(await runner.requests.first?.rowLimit == 25)
        #expect(await runner.requests.first?.connection.adapterID == "bigquery-cli")
        #expect(await runner.requests.first?.connection.projectID == "clinical-prod")
        #expect(await runner.requests.first?.connection.defaultNamespace == "clinical")
    }

    @Test("BigQuery native client rejects non-read SQL")
    func bigQueryNativeClientRejectsNonReadSQL() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        var manifest = Self.reconciliationManifest()
        manifest.sources[0].query = "DELETE FROM `clinical.enrollment_candidates` WHERE true"
        let app = Self.app(for: manifest, workspace: workspace)
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            requirementID: "sourceWarehouse",
            contract: "tabularQuery.read",
            operations: ["runReadOnlyQuery"],
            optional: false,
            status: .mapped,
            implementationID: "bigquery-read-native",
            provider: "bigQuery",
            transport: .native
        )

        await #expect(throws: WorkspaceAppSourceResolutionError.unsupportedSource("warehouse_latest")) {
            try await WorkspaceAppSourceResolver().resolveAsync(
                sourceID: "warehouse_latest",
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: [binding]
            )
        }
    }

    @Test("BigQuery native client rejects manifest supplied SQL even when classified as read")
    func bigQueryNativeClientRejectsManifestSuppliedReadSQL() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        var manifest = Self.reconciliationManifest()
        manifest.sources[0].query = """
        WITH candidates AS (
            SELECT * FROM `clinical.enrollment_candidates`
        )
        SELECT * FROM candidates
        """
        let app = Self.app(for: manifest, workspace: workspace)
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            requirementID: "sourceWarehouse",
            contract: "tabularQuery.read",
            operations: ["runReadOnlyQuery"],
            optional: false,
            status: .mapped,
            implementationID: "bigquery-read-native",
            provider: "bigQuery",
            transport: .native
        )
        let runner = MockWorkspaceAppDatabaseQueryRunner(result: QueryExecutionResult(
            columns: [QueryResultColumn(name: "participant_id", type: "STRING")],
            rows: [["P-001"]],
            rowCount: 1,
            bytesProcessed: 512,
            elapsedMilliseconds: 25,
            jobID: "job-1",
            message: "Query completed."
        ))
        let resolver = WorkspaceAppSourceResolver(
            asyncCapabilityClient: WorkspaceAppNativeAsyncCapabilitySourceClient(queryRunner: runner)
        )

        await #expect(throws: WorkspaceAppSourceResolutionError.unsupportedSource("warehouse_latest")) {
            try await resolver.resolveAsync(
                sourceID: "warehouse_latest",
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: [binding]
            )
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test("async resolver reads REDCap record sources through native client")
    func asyncResolverReadsREDCapRecordSourcesThroughNativeClient() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        let manifest = Self.reconciliationManifest()
        let app = Self.app(for: manifest, workspace: workspace)
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            requirementID: "targetRecords",
            contract: "recordProject.read",
            operations: ["readRecords"],
            optional: false,
            status: .mapped,
            implementationID: "redcap-read-native",
            provider: "redcap",
            transport: .native
        )
        let reader = MockWorkspaceAppREDCapReader(rows: [
            ["record_id": .text("2"), "participant_id": .text("P-002")]
        ])
        let resolver = WorkspaceAppSourceResolver(
            asyncCapabilityClient: WorkspaceAppNativeAsyncCapabilitySourceClient(redcapReader: reader)
        )

        let result = try await resolver.resolveAsync(
            sourceID: "redcap_records",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: [binding],
            input: WorkspaceAppSourceResolutionInput(
                limit: 100,
                parameters: ["record_id": .text("2")]
            )
        )

        #expect(result.rows == [["record_id": .text("2"), "participant_id": .text("P-002")]])
        #expect(result.implementationID == "redcap-read-native")
        #expect(result.provider == "redcap")
        #expect(await reader.requests.first == WorkspaceAppREDCapRequest(
            operation: "readRecords",
            projectRef: "enrollment",
            sourceID: "redcap_records",
            parameters: ["record_id": .text("2")],
            record: [:]
        ))
    }

    @Test("async resolver reads REDCap form schema sources through native client")
    func asyncResolverReadsREDCapFormSchemaSourcesThroughNativeClient() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Forms", primaryPath: root.path)
        var manifest = Self.reconciliationManifest()
        manifest.requirements = [
            WorkspaceAppRequirement(
                id: "targetForms",
                contract: "formSchema.read",
                operations: ["describeFields"],
                providerHint: "redcap"
            )
        ]
        manifest.sources = [
            WorkspaceAppSource(
                id: "redcap_fields",
                requirementRef: "targetForms",
                operation: "describeFields",
                mode: "read",
                projectRef: "enrollment"
            )
        ]
        let app = Self.app(for: manifest, workspace: workspace)
        let binding = WorkspaceAppDependencyBinding(
            workspaceID: workspace.id,
            appID: app.id,
            appLogicalID: app.logicalID,
            requirementID: "targetForms",
            contract: "formSchema.read",
            operations: ["describeFields"],
            optional: false,
            status: .mapped,
            implementationID: "redcap-form-schema-native",
            provider: "redcap",
            transport: .native
        )
        let reader = MockWorkspaceAppREDCapReader(rows: [
            ["field_name": .text("participant_id"), "field_type": .text("text")]
        ])
        let resolver = WorkspaceAppSourceResolver(
            asyncCapabilityClient: WorkspaceAppNativeAsyncCapabilitySourceClient(redcapReader: reader)
        )

        let result = try await resolver.resolveAsync(
            sourceID: "redcap_fields",
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: [binding]
        )

        #expect(result.rows == [["field_name": .text("participant_id"), "field_type": .text("text")]])
        #expect(result.implementationID == "redcap-form-schema-native")
        #expect(await reader.requests.first?.operation == "describeFields")
        #expect(await reader.requests.first?.projectRef == "enrollment")
    }

    @Test("resolver blocks capability sources without mapped dependencies")
    func resolverBlocksCapabilitySourcesWithoutMappedDependencies() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Reconciliation", primaryPath: root.path)
        let manifest = Self.reconciliationManifest()
        let app = Self.app(for: manifest, workspace: workspace)

        #expect(throws: WorkspaceAppSourceResolutionError.missingMappedBinding("sourceWarehouse")) {
            try WorkspaceAppSourceResolver().resolve(
                sourceID: "warehouse_latest",
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: []
            )
        }
    }

    @Test("capability.read resolution never falls through to app storage (storage-shadow source needs its binding)")
    func capabilityReadDoesNotShadowStorage() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Shadow", primaryPath: root.path)
        // A source whose id matches a storage table name AND references a connector requirement. The
        // generic resolveAsync would read the storage table; the connector-only path must NOT.
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "shadow-app", name: "Shadow"),
            requirements: [
                WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                        operations: ["listMyPullRequests"], providerHint: "github")
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "shadow", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "shadow", requirementRef: "github",
                                   operation: "listMyPullRequests", mode: "read")
            ]
        )
        let app = Self.app(for: manifest, workspace: workspace)
        // No mapped binding → the connector path refuses (missingMappedBinding) instead of returning
        // app-storage rows. This is the resolver-side half of the storage-shadow defense.
        await #expect(throws: WorkspaceAppSourceResolutionError.missingMappedBinding("github")) {
            _ = try await WorkspaceAppSourceResolver().resolveCapabilityReadAsync(
                sourceID: "shadow", app: app, workspace: workspace, manifest: manifest, dependencyBindings: []
            )
        }
    }

    @Test("sync capability.read resolution also never falls through to app storage (pipeline-step path)")
    func syncCapabilityReadDoesNotShadowStorage() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Shadow", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "shadow-sync", name: "Shadow"),
            requirements: [
                WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                        operations: ["listMyPullRequests"], providerHint: "github")
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "shadow", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "shadow", requirementRef: "github",
                                   operation: "listMyPullRequests", mode: "read")
            ]
        )
        let app = Self.app(for: manifest, workspace: workspace)
        // The sync connector-only path (used by a capability.read pipeline/loop step) refuses without a
        // mapped binding instead of reading the shadow storage table.
        #expect(throws: WorkspaceAppSourceResolutionError.missingMappedBinding("github")) {
            _ = try WorkspaceAppSourceResolver().resolveCapabilityRead(
                sourceID: "shadow", app: app, workspace: workspace, manifest: manifest, dependencyBindings: []
            )
        }
    }

    // MARK: - Preview live-read binding synthesis (App Studio preview)

    /// The App Studio preview synthesizes the SAME `.mapped` bindings the publish path computes for a
    /// DRAFT (no persisted app), so a connector-read app can be tested live before publishing.
    @Test("preview binding synthesis maps pullRequest.read to .mapped with no workspace connector")
    func previewBindingsMapPullRequestReadWithoutConnector() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Preview", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "pr-tracker", name: "PR Tracker"),
            requirements: [
                WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                        operations: ["listMyPullRequests"], providerHint: "github")
            ]
        )
        let appID = UUID()
        let bindings = WorkspaceAppService().previewDependencyBindings(
            for: manifest.requirements, workspace: workspace, appID: appID, appLogicalID: manifest.app.id)
        #expect(bindings.count == 1)
        let binding = try #require(bindings.first)
        #expect(binding.status == .mapped)            // github-pr-read-native is a built-in → always maps
        #expect(binding.provider == "github")
        #expect(binding.appID == appID)               // scoped to the SAME transient id the read uses
        #expect(binding.requirementID == "github")
    }

    /// The appID-scoping invariant holds even with synthesized bindings: a binding minted for one
    /// transient app id does NOT satisfy a read against a DIFFERENT app id (fails closed before any
    /// network call), so the preview can never resolve a read with a mismatched/forged binding.
    @Test("synthesized bindings are appID-scoped — a mismatched app id fails closed")
    func previewBindingsAreAppIDScoped() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(name: "Preview", primaryPath: root.path)
        let manifest = WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "pr-tracker", name: "PR Tracker"),
            requirements: [
                WorkspaceAppRequirement(id: "github", contract: "pullRequest.read",
                                        operations: ["listMyPullRequests"], providerHint: "github")
            ],
            sources: [
                WorkspaceAppSource(id: "myPRs", requirementRef: "github",
                                   operation: "listMyPullRequests", mode: "read")
            ]
        )
        let bindingAppID = UUID()
        let bindings = WorkspaceAppService().previewDependencyBindings(
            for: manifest.requirements, workspace: workspace, appID: bindingAppID, appLogicalID: manifest.app.id)
        // Resolve with a DIFFERENT app id than the bindings were minted for → missingMappedBinding.
        let otherApp = Self.app(for: manifest, workspace: workspace)   // its own fresh UUID != bindingAppID
        await #expect(throws: WorkspaceAppSourceResolutionError.missingMappedBinding("github")) {
            _ = try await WorkspaceAppSourceResolver().resolveCapabilityReadAsync(
                sourceID: "myPRs", app: otherApp, workspace: workspace, manifest: manifest,
                dependencyBindings: bindings)
        }
    }

    static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-source-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func app(for manifest: WorkspaceAppManifest, workspace: Workspace) -> WorkspaceApp {
        WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
    }

    static func storageManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "inventory-app", name: "Inventory"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "quantity", type: "integer")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "inventory", mode: "read", sourceRef: "items")
            ]
        )
    }

    static func reconciliationManifest() -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "recon", name: "Reconciliation"),
            requirements: [
                WorkspaceAppRequirement(
                    id: "sourceWarehouse",
                    contract: "tabularQuery.read",
                    operations: ["runReadOnlyQuery"],
                    providerHint: "bigQuery"
                ),
                WorkspaceAppRequirement(
                    id: "targetRecords",
                    contract: "recordProject.read",
                    operations: ["readRecords"],
                    providerHint: "redcap"
                )
            ],
            sources: [
                WorkspaceAppSource(
                    id: "warehouse_latest",
                    requirementRef: "sourceWarehouse",
                    operation: "runReadOnlyQuery",
                    mode: "read",
                    tableRef: "clinical.enrollment_candidates"
                ),
                WorkspaceAppSource(
                    id: "redcap_records",
                    requirementRef: "targetRecords",
                    operation: "readRecords",
                    mode: "read",
                    projectRef: "enrollment"
                )
            ]
        )
    }
}

private actor MockWorkspaceAppREDCapReader: WorkspaceAppREDCapReading {
    private(set) var requests: [WorkspaceAppREDCapRequest] = []
    var rows: [[String: WorkspaceAppStorageValue]]

    init(rows: [[String: WorkspaceAppStorageValue]]) {
        self.rows = rows
    }

    func read(_ request: WorkspaceAppREDCapRequest) async throws -> [[String: WorkspaceAppStorageValue]] {
        requests.append(request)
        return rows
    }
}

private actor MockWorkspaceAppDatabaseQueryRunner: WorkspaceAppDatabaseQueryRunning {
    private(set) var requests: [QueryRequest] = []
    var result: QueryExecutionResult

    init(result: QueryExecutionResult) {
        self.result = result
    }

    func run(_ request: QueryRequest) async throws -> QueryExecutionResult {
        requests.append(request)
        return result
    }
}

private struct MockCapabilitySourceClient: WorkspaceAppCapabilitySourceClient {
    var rowsBySourceID: [String: [[String: WorkspaceAppStorageValue]]]

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) throws -> [[String: WorkspaceAppStorageValue]] {
        rowsBySourceID[source.id] ?? []
    }
}
