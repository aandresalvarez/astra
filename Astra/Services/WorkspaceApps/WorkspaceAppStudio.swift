import Foundation

struct WorkspaceAppStudioProposal: Sendable, Equatable {
    var name: String
    var problem: String
    var storage: [String]
    var views: [String]
    var actions: [String]
    var automation: [String]
    var riskMode: WorkspaceAppPermissionMode
}

struct WorkspaceAppStudioDraft: Identifiable, Sendable, Equatable {
    var id: UUID
    var workspaceID: UUID
    var sourceAppID: UUID?
    var intent: String
    var proposal: WorkspaceAppStudioProposal
    var manifest: WorkspaceAppManifest
    var validationReport: WorkspaceAppManifestValidationReport

    var canPublish: Bool {
        validationReport.isValid
    }
}

struct WorkspaceAppStudioManifestPatchOperation: Codable, Sendable, Equatable {
    var op: String
    var path: String
    var value: WorkspaceAppStudioPatchValue?

    enum CodingKeys: String, CodingKey {
        case op
        case path
        case value
    }

    init(op: String, path: String, value: WorkspaceAppStudioPatchValue? = nil) {
        self.op = op
        self.path = path
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(String.self, forKey: .op)
        path = try container.decode(String.self, forKey: .path)
        guard container.contains(.value) else {
            value = nil
            return
        }

        let parts = path.split(separator: "/").map(String.init)
        if parts == ["app", "name"] || parts == ["app", "description"] || parts == ["app", "icon"] {
            value = .string(try container.decode(String.self, forKey: .value))
        } else if parts == ["app", "tags"] || parts == ["app", "archetypes"] {
            value = .stringArray(try container.decode([String].self, forKey: .value))
        } else if parts == ["permissions"] {
            value = .permissions(try container.decode(WorkspaceAppPermissions.self, forKey: .value))
        } else if parts.count == 3 && parts[0] == "storage" && parts[1] == "tables" {
            value = .storageTable(try container.decode(WorkspaceAppStorageTable.self, forKey: .value))
        } else if parts.count == 2 && parts[0] == "views" {
            value = .view(try container.decode(WorkspaceAppViewSpec.self, forKey: .value))
        } else if parts.count == 2 && parts[0] == "actions" {
            value = .action(try container.decode(WorkspaceAppActionSpec.self, forKey: .value))
        } else if parts.count == 2 && parts[0] == "automations" {
            value = .automation(try container.decode(WorkspaceAppAutomationSpec.self, forKey: .value))
        } else {
            value = try container.decode(WorkspaceAppStudioPatchValue.self, forKey: .value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(op, forKey: .op)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(value, forKey: .value)
    }
}

enum WorkspaceAppStudioPatchValue: Codable, Sendable, Equatable {
    case string(String)
    case stringArray([String])
    case storageTable(WorkspaceAppStorageTable)
    case view(WorkspaceAppViewSpec)
    case action(WorkspaceAppActionSpec)
    case automation(WorkspaceAppAutomationSpec)
    case permissions(WorkspaceAppPermissions)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String].self) {
            self = .stringArray(value)
        } else if let value = try? container.decode(WorkspaceAppStorageTable.self), !value.name.isEmpty {
            self = .storageTable(value)
        } else if let value = try? container.decode(WorkspaceAppViewSpec.self) {
            self = .view(value)
        } else if let value = try? container.decode(WorkspaceAppActionSpec.self) {
            self = .action(value)
        } else if let value = try? container.decode(WorkspaceAppAutomationSpec.self) {
            self = .automation(value)
        } else {
            self = .permissions(try container.decode(WorkspaceAppPermissions.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .stringArray(let value):
            try container.encode(value)
        case .storageTable(let value):
            try container.encode(value)
        case .view(let value):
            try container.encode(value)
        case .action(let value):
            try container.encode(value)
        case .automation(let value):
            try container.encode(value)
        case .permissions(let value):
            try container.encode(value)
        }
    }
}

struct WorkspaceAppStudioPatchResult: Sendable, Equatable {
    var manifest: WorkspaceAppManifest
    var rejectedManifest: WorkspaceAppManifest?
    var validationReport: WorkspaceAppManifestValidationReport
    var accepted: Bool

    var canPublish: Bool {
        accepted && validationReport.isValid
    }
}

enum WorkspaceAppStudioStructuredOutputKind: String, Sendable, Equatable {
    case manifest
    case patch
}

struct WorkspaceAppStudioStructuredOutputResult: Sendable, Equatable {
    var kind: WorkspaceAppStudioStructuredOutputKind?
    var manifest: WorkspaceAppManifest
    var rejectedManifest: WorkspaceAppManifest?
    var validationReport: WorkspaceAppManifestValidationReport
    var accepted: Bool

    var canPublish: Bool {
        accepted && validationReport.isValid
    }
}

enum WorkspaceAppStudioBuilder {
    static let defaultIntent = "Build me a database app to store my groceries."

    static func draft(
        intent rawIntent: String,
        workspace: Workspace,
        existingManifest: WorkspaceAppManifest? = nil
    ) -> WorkspaceAppStudioDraft {
        let intent = normalizedIntent(rawIntent)
        let manifest = existingManifest ?? manifest(for: intent)
        let proposal = proposal(for: intent, manifest: manifest)
        let report = WorkspaceAppManifestValidator.validate(manifest)

        return WorkspaceAppStudioDraft(
            id: UUID(),
            workspaceID: workspace.id,
            sourceAppID: nil,
            intent: intent,
            proposal: proposal,
            manifest: manifest,
            validationReport: report
        )
    }

    static func draft(
        from idea: WorkspaceAppStudioIdea,
        workspace: Workspace
    ) -> WorkspaceAppStudioDraft {
        let manifest = manifest(for: idea)
        let proposal = WorkspaceAppStudioProposal(
            name: idea.name,
            problem: idea.problem,
            storage: idea.appStorage,
            views: idea.mainViews,
            actions: idea.actions,
            automation: idea.automation,
            riskMode: idea.riskMode
        )
        let report = WorkspaceAppManifestValidator.validate(manifest)
        return WorkspaceAppStudioDraft(
            id: UUID(),
            workspaceID: workspace.id,
            sourceAppID: nil,
            intent: idea.accelerationRationale,
            proposal: proposal,
            manifest: manifest,
            validationReport: report
        )
    }

    static func manifestForPublishing(
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

    static func applyPatch(
        _ operations: [WorkspaceAppStudioManifestPatchOperation],
        to manifest: WorkspaceAppManifest
    ) -> WorkspaceAppStudioPatchResult {
        do {
            var patched = manifest
            for operation in operations {
                try apply(operation, to: &patched)
            }
            let report = WorkspaceAppManifestValidator.validate(patched)
            guard report.isValid else {
                return WorkspaceAppStudioPatchResult(
                    manifest: manifest,
                    rejectedManifest: patched,
                    validationReport: report,
                    accepted: false
                )
            }
            return WorkspaceAppStudioPatchResult(
                manifest: patched,
                rejectedManifest: nil,
                validationReport: report,
                accepted: true
            )
        } catch let error as WorkspaceAppStudioPatchError {
            return WorkspaceAppStudioPatchResult(
                manifest: manifest,
                rejectedManifest: nil,
                validationReport: WorkspaceAppManifestValidationReport(issues: [
                    WorkspaceAppManifestValidationReport.Issue(
                        severity: .blocker,
                        path: error.path,
                        message: error.message
                    )
                ]),
                accepted: false
            )
        } catch {
            return WorkspaceAppStudioPatchResult(
                manifest: manifest,
                rejectedManifest: nil,
                validationReport: WorkspaceAppManifestValidationReport(issues: [
                    WorkspaceAppManifestValidationReport.Issue(
                        severity: .blocker,
                        path: "/patch",
                        message: "Could not apply manifest patch: \(error.localizedDescription)"
                    )
                ]),
                accepted: false
            )
        }
    }

    static func applyStructuredOutput(
        _ output: String,
        to manifest: WorkspaceAppManifest
    ) -> WorkspaceAppStudioStructuredOutputResult {
        let manifestBlock = structuredBlock(
            named: "ASTRA_APP_MANIFEST",
            in: output
        )
        let patchBlock = structuredBlock(
            named: "ASTRA_APP_PATCH",
            in: output
        )

        switch (manifestBlock, patchBlock) {
        case (.success(let manifestPayload), .notFound):
            return applyManifestPayload(manifestPayload, preserving: manifest)
        case (.notFound, .success(let patchPayload)):
            return applyPatchPayload(patchPayload, to: manifest)
        case (.notFound, .notFound):
            return structuredOutputFailure(
                preserving: manifest,
                path: "/structuredOutput",
                message: "No ASTRA app manifest or patch block was found."
            )
        case (.success, .success):
            return structuredOutputFailure(
                preserving: manifest,
                path: "/structuredOutput",
                message: "Structured output must include either ASTRA_APP_MANIFEST or ASTRA_APP_PATCH, not both."
            )
        case (.failure(let message), _):
            return structuredOutputFailure(
                preserving: manifest,
                path: "/structuredOutput/ASTRA_APP_MANIFEST",
                message: message
            )
        case (_, .failure(let message)):
            return structuredOutputFailure(
                preserving: manifest,
                path: "/structuredOutput/ASTRA_APP_PATCH",
                message: message
            )
        }
    }

    private static func manifest(for intent: String) -> WorkspaceAppManifest {
        // Route free-text intent to the best-fitting archetype recipe instead of collapsing
        // every non-"database" intent into a read-only operational surface.
        WorkspaceAppStudioRecipes.manifest(for: WorkspaceAppArchetype.classify(intent), intent: intent)
    }

    /// The deterministic template manifest for a free-text intent.
    ///
    /// `WorkspaceAppStudioGenerator` uses this both as the graceful fallback when
    /// the model is unavailable or never produces a valid manifest, and as the
    /// valid few-shot example embedded in the generation prompt. It is the only
    /// manifest-only entry point — `draft(intent:workspace:)` additionally needs a
    /// `Workspace` to build a draft, which the value-typed generator must not require.
    static func baseManifest(intent: String) -> WorkspaceAppManifest {
        manifest(for: normalizedIntent(intent))
    }

    private static func manifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        if idea.id == "bq-redcap-reconciliation" {
            return reconciliationManifest(for: idea)
        }
        if idea.id == "pipeline-review-queue" {
            return pipelineReviewQueueManifest(for: idea)
        }
        if idea.id == "weekly-report-generator" {
            return reportGeneratorManifest(for: idea)
        }
        if idea.id == "agentic-workflow" {
            return agenticWorkflowManifest(for: idea)
        }
        if idea.id == "parallel-agent-review" {
            return parallelAgenticWorkflowManifest(for: idea)
        }
        return operationalSurfaceManifest(intent: idea.name)
    }

    private static func applyManifestPayload(
        _ payload: String,
        preserving manifest: WorkspaceAppManifest
    ) -> WorkspaceAppStudioStructuredOutputResult {
        do {
            let decoded = try JSONDecoder().decode(
                WorkspaceAppManifest.self,
                from: Data(payload.utf8)
            )
            let report = WorkspaceAppManifestValidator.validate(decoded)
            guard report.isValid else {
                return WorkspaceAppStudioStructuredOutputResult(
                    kind: .manifest,
                    manifest: manifest,
                    rejectedManifest: decoded,
                    validationReport: report,
                    accepted: false
                )
            }
            return WorkspaceAppStudioStructuredOutputResult(
                kind: .manifest,
                manifest: decoded,
                rejectedManifest: nil,
                validationReport: report,
                accepted: true
            )
        } catch {
            return structuredOutputFailure(
                preserving: manifest,
                path: "/structuredOutput/ASTRA_APP_MANIFEST",
                message: "Could not decode app manifest block: \(error.localizedDescription)"
            )
        }
    }

    private static func applyPatchPayload(
        _ payload: String,
        to manifest: WorkspaceAppManifest
    ) -> WorkspaceAppStudioStructuredOutputResult {
        do {
            let operations = try JSONDecoder().decode(
                [WorkspaceAppStudioManifestPatchOperation].self,
                from: Data(payload.utf8)
            )
            let patchResult = applyPatch(operations, to: manifest)
            return WorkspaceAppStudioStructuredOutputResult(
                kind: .patch,
                manifest: patchResult.manifest,
                rejectedManifest: patchResult.rejectedManifest,
                validationReport: patchResult.validationReport,
                accepted: patchResult.accepted
            )
        } catch {
            return structuredOutputFailure(
                preserving: manifest,
                path: "/structuredOutput/ASTRA_APP_PATCH",
                message: "Could not decode app patch block: \(error.localizedDescription)"
            )
        }
    }

    private static func structuredOutputFailure(
        preserving manifest: WorkspaceAppManifest,
        path: String,
        message: String
    ) -> WorkspaceAppStudioStructuredOutputResult {
        WorkspaceAppStudioStructuredOutputResult(
            kind: nil,
            manifest: manifest,
            rejectedManifest: nil,
            validationReport: WorkspaceAppManifestValidationReport(issues: [
                WorkspaceAppManifestValidationReport.Issue(
                    severity: .blocker,
                    path: path,
                    message: message
                )
            ]),
            accepted: false
        )
    }

    private static func structuredBlock(
        named name: String,
        in output: String
    ) -> WorkspaceAppStudioStructuredBlock {
        let endMarker = "END_\(name)"
        let lines = output.components(separatedBy: .newlines)
        let startIndexes = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == name }
        guard let startIndex = startIndexes.first else {
            return .notFound
        }
        guard startIndexes.count == 1 else {
            return .failure("Structured output includes multiple \(name) blocks.")
        }
        guard let endIndex = lines.indices[(startIndex + 1)...].first(where: {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == endMarker
        }) else {
            return .failure("Structured output is missing \(endMarker).")
        }
        let payload = lines[(startIndex + 1)..<endIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return .failure("Structured output \(name) block is empty.")
        }
        return .success(payload)
    }

    private static func apply(
        _ operation: WorkspaceAppStudioManifestPatchOperation,
        to manifest: inout WorkspaceAppManifest
    ) throws {
        let parts = operation.path.split(separator: "/").map(String.init)
        switch operation.op {
        case "add":
            try add(operation.value, at: parts, path: operation.path, manifest: &manifest)
        case "replace":
            try replace(operation.value, at: parts, path: operation.path, manifest: &manifest)
        case "remove":
            try remove(at: parts, path: operation.path, manifest: &manifest)
        default:
            throw WorkspaceAppStudioPatchError(path: operation.path, message: "Unsupported patch operation '\(operation.op)'.")
        }
    }

    private static func add(
        _ value: WorkspaceAppStudioPatchValue?,
        at parts: [String],
        path: String,
        manifest: inout WorkspaceAppManifest
    ) throws {
        if parts == ["storage", "tables", "-"] {
            let table = try storageTableValue(value, path: path)
            if manifest.storage == nil {
                manifest.storage = WorkspaceAppStorageSchema()
            }
            manifest.storage?.tables.append(table)
        } else if parts == ["views", "-"] {
            manifest.views.append(try viewValue(value, path: path))
        } else if parts == ["actions", "-"] {
            manifest.actions.append(try actionValue(value, path: path))
        } else if parts == ["automations", "-"] {
            manifest.automations.append(try automationValue(value, path: path))
        } else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Unsupported add patch path.")
        }
    }

    private static func replace(
        _ value: WorkspaceAppStudioPatchValue?,
        at parts: [String],
        path: String,
        manifest: inout WorkspaceAppManifest
    ) throws {
        if parts == ["app", "name"] {
            manifest.app.name = try stringValue(value, path: path)
        } else if parts == ["app", "description"] {
            manifest.app.description = try stringValue(value, path: path)
        } else if parts == ["app", "icon"] {
            manifest.app.icon = try stringValue(value, path: path)
        } else if parts == ["app", "tags"] {
            manifest.app.tags = try stringArrayValue(value, path: path)
        } else if parts == ["app", "archetypes"] {
            manifest.app.archetypes = try stringArrayValue(value, path: path)
        } else if parts == ["permissions"] {
            manifest.permissions = try permissionsValue(value, path: path)
        } else if parts.count == 3 && parts[0] == "storage" && parts[1] == "tables" {
            guard manifest.storage != nil else {
                throw WorkspaceAppStudioPatchError(path: path, message: "Cannot replace a storage table when the manifest has no storage schema.")
            }
            let index = parts[2]
            let resolved = try existingIndex(index, count: manifest.storage?.tables.count ?? 0, path: path)
            manifest.storage?.tables[resolved] = try storageTableValue(value, path: path)
        } else if parts.count == 2 && parts[0] == "views" {
            let index = parts[1]
            manifest.views[try existingIndex(index, count: manifest.views.count, path: path)] = try viewValue(value, path: path)
        } else if parts.count == 2 && parts[0] == "actions" {
            let index = parts[1]
            manifest.actions[try existingIndex(index, count: manifest.actions.count, path: path)] = try actionValue(value, path: path)
        } else if parts.count == 2 && parts[0] == "automations" {
            let index = parts[1]
            manifest.automations[try existingIndex(index, count: manifest.automations.count, path: path)] = try automationValue(value, path: path)
        } else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Unsupported replace patch path.")
        }
    }

    private static func remove(
        at parts: [String],
        path: String,
        manifest: inout WorkspaceAppManifest
    ) throws {
        if parts.count == 3 && parts[0] == "storage" && parts[1] == "tables" {
            guard var storage = manifest.storage else {
                throw WorkspaceAppStudioPatchError(path: path, message: "Cannot remove a storage table when the manifest has no storage schema.")
            }
            let index = parts[2]
            storage.tables.remove(at: try existingIndex(index, count: storage.tables.count, path: path))
            manifest.storage = storage
        } else if parts.count == 2 && parts[0] == "views" {
            let index = parts[1]
            manifest.views.remove(at: try existingIndex(index, count: manifest.views.count, path: path))
        } else if parts.count == 2 && parts[0] == "actions" {
            let index = parts[1]
            manifest.actions.remove(at: try existingIndex(index, count: manifest.actions.count, path: path))
        } else if parts.count == 2 && parts[0] == "automations" {
            let index = parts[1]
            manifest.automations.remove(at: try existingIndex(index, count: manifest.automations.count, path: path))
        } else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Unsupported remove patch path.")
        }
    }

    private static func stringValue(_ value: WorkspaceAppStudioPatchValue?, path: String) throws -> String {
        guard case .string(let string) = value else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch value must be a string.")
        }
        return string
    }

    private static func stringArrayValue(_ value: WorkspaceAppStudioPatchValue?, path: String) throws -> [String] {
        guard case .stringArray(let strings) = value else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch value must be a string array.")
        }
        return strings
    }

    private static func storageTableValue(_ value: WorkspaceAppStudioPatchValue?, path: String) throws -> WorkspaceAppStorageTable {
        guard case .storageTable(let table) = value else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch value must be a storage table.")
        }
        return table
    }

    private static func viewValue(_ value: WorkspaceAppStudioPatchValue?, path: String) throws -> WorkspaceAppViewSpec {
        guard case .view(let view) = value else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch value must be a view.")
        }
        return view
    }

    private static func actionValue(_ value: WorkspaceAppStudioPatchValue?, path: String) throws -> WorkspaceAppActionSpec {
        guard case .action(let action) = value else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch value must be an action.")
        }
        return action
    }

    private static func automationValue(_ value: WorkspaceAppStudioPatchValue?, path: String) throws -> WorkspaceAppAutomationSpec {
        guard case .automation(let automation) = value else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch value must be an automation.")
        }
        return automation
    }

    private static func permissionsValue(_ value: WorkspaceAppStudioPatchValue?, path: String) throws -> WorkspaceAppPermissions {
        guard case .permissions(let permissions) = value else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch value must be app permissions.")
        }
        return permissions
    }

    private static func existingIndex(_ rawValue: String, count: Int, path: String) throws -> Int {
        guard let index = Int(rawValue), index >= 0, index < count else {
            throw WorkspaceAppStudioPatchError(path: path, message: "Patch index is outside the current manifest collection.")
        }
        return index
    }

    private static func proposal(
        for intent: String,
        manifest: WorkspaceAppManifest
    ) -> WorkspaceAppStudioProposal {
        WorkspaceAppStudioProposal(
            name: manifest.app.name,
            problem: manifest.app.description,
            storage: manifest.storage?.tables.map(\.name) ?? [],
            views: manifest.views.map { $0.title ?? $0.id },
            actions: manifest.actions.map { $0.label ?? $0.id },
            automation: manifest.automations.map(\.id),
            riskMode: manifest.permissions.defaultMode
        )
    }

    static func localDatabaseManifest(intent: String) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: "grocery-tracker",
                name: "Grocery Tracker",
                icon: "cart",
                description: "Track grocery items, shopping lists, stores, and purchases from a local app database.",
                tags: ["local-storage", "database"],
                archetypes: ["Local Database App", "Action Panel"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "category", type: "text"),
                    WorkspaceAppStorageColumn(name: "preferred_store", type: "text"),
                    WorkspaceAppStorageColumn(name: "last_price", type: "double"),
                    WorkspaceAppStorageColumn(name: "in_stock", type: "bool")
                ]),
                WorkspaceAppStorageTable(name: "shopping_lists", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true)
                ]),
                WorkspaceAppStorageTable(name: "purchases", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "item_id", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "store", type: "text"),
                    WorkspaceAppStorageColumn(name: "price", type: "double"),
                    WorkspaceAppStorageColumn(name: "purchased_at", type: "date")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "local_grocery_tables", mode: "read", sourceRef: "appStorage")
            ],
            views: [
                WorkspaceAppViewSpec(id: "items_table", type: "table", title: "Items", table: "items"),
                WorkspaceAppViewSpec(id: "shopping_list", type: "form", title: "Shopping List"),
                WorkspaceAppViewSpec(
                    id: "spend_metrics",
                    type: "dashboard",
                    title: "Spend Metrics",
                    table: "purchases",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "item_count",
                            type: "metric",
                            label: "Tracked items",
                            table: "items",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "total_spend",
                            type: "metric",
                            label: "Total spend",
                            field: "price",
                            aggregation: "sum"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "spend_by_store",
                            type: "chart",
                            label: "Spend by store",
                            field: "price",
                            groupBy: "store",
                            aggregation: "sum"
                        )
                    ]
                )
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_items", type: "appStorage.query", label: "List Items", table: "items"),
                WorkspaceAppActionSpec(id: "add_item", type: "appStorage.insert", label: "Add Item", table: "items"),
                WorkspaceAppActionSpec(id: "update_item", type: "appStorage.update", label: "Update Item", table: "items"),
                WorkspaceAppActionSpec(id: "delete_item", type: "appStorage.delete", label: "Delete Item", table: "items"),
                WorkspaceAppActionSpec(
                    id: "create_shopping_task",
                    type: "task.createDraft",
                    label: "Create Shopping Task",
                    taskTitle: "Plan next grocery trip",
                    taskGoal: "Review the grocery tracker records and draft a focused shopping plan for the next trip."
                ),
                WorkspaceAppActionSpec(
                    id: "export_items",
                    type: "artifact.export",
                    label: "Export Items",
                    table: "items",
                    exportFormat: "csv"
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["appStorage.records"],
                writes: ["appStorage.records"],
                defaultMode: .draftOnly
            )
        )
    }

    static func operationalSurfaceManifest(intent: String) -> WorkspaceAppManifest {
        let name = title(from: intent)
        let id = slug(from: name)
        return WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: id,
                name: name,
                icon: "rectangle.3.group",
                description: "Draft operational app surface generated from the requested workflow.",
                tags: ["draft", "workspace-app"],
                archetypes: ["Dashboard", "Action Panel"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "notes", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_context", mode: "read", sourceRef: "workspace")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "overview",
                    type: "dashboard",
                    title: "Overview",
                    table: "review_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "review_item_count",
                            type: "metric",
                            label: "Review items",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "review_status_chart",
                            type: "chart",
                            label: "Items by status",
                            groupBy: "status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "review_queue", type: "table", title: "Review Queue", table: "review_items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_review_items", type: "appStorage.query", label: "List Review Items", table: "review_items"),
                // A populating path: the Add action renders an inline record form so the app can
                // fill its own storage. Without this the dashboard/table render over an empty table
                // the user can never fill (the read-only-shell defect).
                WorkspaceAppActionSpec(id: "add_review_item", type: "appStorage.insert", label: "Add Item", table: "review_items"),
                WorkspaceAppActionSpec(id: "update_review_item", type: "appStorage.update", label: "Update Item", table: "review_items"),
                WorkspaceAppActionSpec(id: "delete_review_item", type: "appStorage.delete", label: "Delete Item", table: "review_items"),
                WorkspaceAppActionSpec(
                    id: "create_review_task",
                    type: "task.createDraft",
                    label: "Create Review Task",
                    taskTitle: "Review workspace app items",
                    taskGoal: "Review the current app records, identify the next manual decision, and summarize recommended follow-up."
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: .draftOnly
            )
        )
    }

    private static func reconciliationManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "checklist.checked",
                description: idea.problem,
                tags: ["reconciliation", "redcap", "bigquery"],
                archetypes: ["Reconciliation App", "Dashboard", "Review Queue"]
            ),
            requirements: [
                WorkspaceAppRequirement(
                    id: "sourceWarehouse",
                    contract: "tabularQuery.read",
                    minVersion: "1.0.0",
                    operations: ["describeTable", "runReadOnlyQuery"],
                    providerHint: "bigQuery",
                    dataClass: "sensitive"
                ),
                WorkspaceAppRequirement(
                    id: "targetRecords",
                    contract: "recordProject.read",
                    minVersion: "1.0.0",
                    operations: ["describeProject", "readRecords", "validateRecord"],
                    providerHint: "redcap",
                    dataClass: "sensitive"
                )
            ],
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "source_record_id", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "match_status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "notes", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(
                    id: "latest_candidates",
                    requirementRef: "sourceWarehouse",
                    operation: "runReadOnlyQuery",
                    mode: "read",
                    query: "SELECT * FROM clinical.enrollment_candidates ORDER BY updated_at DESC LIMIT 100"
                ),
                WorkspaceAppSource(
                    id: "redcap_records",
                    requirementRef: "targetRecords",
                    operation: "readRecords",
                    mode: "read",
                    projectRef: "enrollment-study"
                )
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "dashboard",
                    type: "dashboard",
                    title: "Reconciliation Dashboard",
                    table: "review_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "review_count",
                            type: "metric",
                            label: "Records to review",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "status_chart",
                            type: "chart",
                            label: "Records by status",
                            groupBy: "match_status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "exceptions", type: "reviewQueue", title: "Exceptions", table: "review_items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_review_items", type: "appStorage.query", label: "List Review Items", table: "review_items"),
                WorkspaceAppActionSpec(id: "refresh", type: "pipeline.run", label: "Refresh", steps: ["list_review_items"]),
                WorkspaceAppActionSpec(
                    id: "create_review_task",
                    type: "task.createDraft",
                    label: "Create Review Task",
                    taskTitle: "Review missing REDCap records",
                    taskGoal: "Review missing or ambiguous REDCap records from the reconciliation app and recommend follow-up."
                ),
                WorkspaceAppActionSpec(
                    id: "export_missing",
                    type: "artifact.export",
                    label: "Export Missing Records",
                    table: "review_items",
                    exportFormat: "csv"
                )
            ],
            automations: [
                WorkspaceAppAutomationSpec(id: "daily_refresh", type: "schedule", action: "refresh")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["tabularQuery.read", "recordProject.read"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: idea.riskMode
            )
        )
    }

    private static func pipelineReviewQueueManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "arrow.triangle.branch",
                description: idea.problem,
                tags: ["pipeline", "review"],
                archetypes: ["Pipeline", "Review Queue"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "pipeline_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "step", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "owner", type: "text"),
                    WorkspaceAppStorageColumn(name: "updated_at", type: "datetime")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_process", mode: "read", sourceRef: "conversation")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "pipeline_overview",
                    type: "pipelineRun",
                    title: "Pipeline Overview",
                    table: "pipeline_items",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "step_count",
                            type: "metric",
                            label: "Tracked steps",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "status_breakdown",
                            type: "chart",
                            label: "Steps by status",
                            groupBy: "status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "approval_queue", type: "reviewQueue", title: "Approval Queue", table: "pipeline_items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_pipeline_items", type: "appStorage.query", label: "List Pipeline Items", table: "pipeline_items"),
                WorkspaceAppActionSpec(id: "run_pipeline", type: "pipeline.run", label: "Run Pipeline", steps: ["list_pipeline_items"]),
                WorkspaceAppActionSpec(
                    id: "create_followup_task",
                    type: "task.createDraft",
                    label: "Create Follow-up Task",
                    taskTitle: "Follow up on pipeline exception",
                    taskGoal: "Review the selected pipeline exception, identify the blocker, and draft the next action."
                )
            ],
            automations: [
                WorkspaceAppAutomationSpec(id: "weekday_monitor", type: "monitor", action: "run_pipeline")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: idea.riskMode
            )
        )
    }

    // Slice 9 Phase A: an Agentic Workflow app orchestrates a workflow of governed
    // ASTRA agents. It composes existing primitives only — task-backed steps run
    // through the normal task runtime (spec 16.5), separated by an agent
    // recommendation gate and a human approval gate, and bounded by a loop with a
    // stop condition. No parallel agent runtime is introduced.
    private static func agenticWorkflowManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "person.3.sequence",
                description: idea.problem,
                tags: ["agentic", "workflow"],
                archetypes: ["Agentic Workflow"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "workflow_runs", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "step", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "summary", type: "text"),
                    WorkspaceAppStorageColumn(name: "updated_at", type: "datetime")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_process", mode: "read", sourceRef: "conversation")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "workflow_overview",
                    type: "pipelineRun",
                    title: "Workflow",
                    table: "workflow_runs",
                    widgets: [
                        WorkspaceAppWidgetSpec(id: "run_count", type: "metric", label: "Recorded steps", aggregation: "count"),
                        WorkspaceAppWidgetSpec(id: "status_breakdown", type: "chart", label: "Steps by status", groupBy: "status", aggregation: "count")
                    ]
                ),
                WorkspaceAppViewSpec(id: "run_history", type: "reviewQueue", title: "Run History", table: "workflow_runs")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "analyze",
                    type: "task.createAndRun",
                    label: "Analyze",
                    taskTitle: "Analyze the problem",
                    taskGoal: "Analyze the workflow problem and produce findings the implementation step can act on."
                ),
                WorkspaceAppActionSpec(
                    id: "agent_review",
                    type: "gate.agentRecommendation",
                    label: "Agent review",
                    agentPrompt: "Review the analysis and recommend whether to continue to implementation, revise the analysis, or stop the workflow.",
                    agentDecisions: ["continue", "revise", "stop"],
                    agentPolicyMode: "approvalRequired",
                    agentTokenBudget: 20_000,
                    agentRequiresApproval: true
                ),
                WorkspaceAppActionSpec(
                    id: "human_approval",
                    type: "gate.humanApproval",
                    label: "Human approval",
                    approvalPrompt: "Approve the agent's recommendation before the workflow implements changes?",
                    approvalDecisions: ["approve", "reject"]
                ),
                WorkspaceAppActionSpec(
                    id: "implement",
                    type: "task.createAndRun",
                    label: "Implement",
                    taskTitle: "Implement the approved plan",
                    taskGoal: "Implement the approved plan from the analysis and record the outcome in app storage."
                ),
                WorkspaceAppActionSpec(
                    id: "record_outcome",
                    type: "appStorage.insert",
                    label: "Record outcome",
                    table: "workflow_runs"
                ),
                WorkspaceAppActionSpec(
                    id: "run_workflow",
                    type: "pipeline.run",
                    label: "Run workflow",
                    steps: ["analyze", "agent_review", "human_approval", "implement", "record_outcome"]
                ),
                WorkspaceAppActionSpec(
                    id: "iterate_until_done",
                    type: "loop.run",
                    label: "Iterate until done",
                    gateField: "status",
                    gateOperator: "equals",
                    gateValue: .text("done"),
                    steps: ["run_workflow"],
                    maxIterations: 5,
                    timeoutSeconds: 3600,
                    delaySeconds: 0
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts", "task.runs"],
                defaultMode: idea.riskMode
            )
        )
    }

    /// A PARALLEL agentic workflow: fan one governed agent task out over every row of an
    /// app-owned worklist, then reduce the fan-in into a single summary. Surfaces the Phase C
    /// `task.fanOut` + `rows.reduce` primitives from the builder (the linear archetype only
    /// chains sequential steps).
    private static func parallelAgenticWorkflowManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "person.3.sequence",
                description: idea.problem,
                tags: ["agentic", "workflow", "parallel"],
                archetypes: ["Agentic Workflow", "Parallel Review"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true)
                ]),
                WorkspaceAppStorageTable(name: "review_summaries", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "reviewed_count", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "summary", type: "text"),
                    WorkspaceAppStorageColumn(name: "updated_at", type: "datetime")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_process", mode: "read", sourceRef: "conversation")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "review_overview",
                    type: "pipelineRun",
                    title: "Parallel Review",
                    table: "review_summaries",
                    widgets: [
                        WorkspaceAppWidgetSpec(id: "summary_count", type: "metric", label: "Summaries", aggregation: "count")
                    ]
                ),
                WorkspaceAppViewSpec(id: "worklist", type: "reviewQueue", title: "Worklist", table: "review_items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list_items", type: "appStorage.query", label: "List Items", table: "review_items"),
                WorkspaceAppActionSpec(
                    id: "review_one",
                    type: "task.createAndRun",
                    label: "Review one item",
                    taskTitle: "Review a worklist item",
                    taskGoal: "Review the bound worklist item and produce a verdict the summary step can fold."
                ),
                WorkspaceAppActionSpec(
                    id: "fan_out_reviews",
                    type: "task.fanOut",
                    label: "Review all items in parallel",
                    fanOutStep: "review_one"
                ),
                WorkspaceAppActionSpec(
                    id: "summarize_reviews",
                    type: "rows.reduce",
                    label: "Summarize reviews",
                    reduceStrategy: "count"
                ),
                WorkspaceAppActionSpec(
                    id: "record_summary",
                    type: "appStorage.insert",
                    label: "Record summary",
                    table: "review_summaries"
                ),
                WorkspaceAppActionSpec(
                    id: "run_parallel_review",
                    type: "pipeline.run",
                    label: "Run parallel review",
                    steps: ["list_items", "fan_out_reviews", "summarize_reviews", "record_summary"]
                )
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts", "task.runs"],
                defaultMode: idea.riskMode
            )
        )
    }

    private static func reportGeneratorManifest(for idea: WorkspaceAppStudioIdea) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(
                id: idea.id,
                name: idea.name,
                icon: "doc.text.magnifyingglass",
                description: idea.problem,
                tags: ["report", "artifact"],
                archetypes: ["Report Generator", "Dashboard"]
            ),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "report_runs", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "period", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "artifact_path", type: "text")
                ])
            ]),
            sources: [
                WorkspaceAppSource(id: "workspace_artifacts", mode: "read", sourceRef: "artifacts")
            ],
            views: [
                WorkspaceAppViewSpec(
                    id: "report_dashboard",
                    type: "dashboard",
                    title: "Report Dashboard",
                    table: "report_runs",
                    widgets: [
                        WorkspaceAppWidgetSpec(
                            id: "report_count",
                            type: "metric",
                            label: "Reports",
                            aggregation: "count"
                        ),
                        WorkspaceAppWidgetSpec(
                            id: "report_status",
                            type: "chart",
                            label: "Reports by status",
                            groupBy: "status",
                            aggregation: "count"
                        )
                    ]
                ),
                WorkspaceAppViewSpec(id: "report_history", type: "table", title: "Report History", table: "report_runs")
            ],
            actions: [
                WorkspaceAppActionSpec(
                    id: "draft_report_task",
                    type: "task.createDraft",
                    label: "Draft Report Task",
                    taskTitle: "Generate workspace report",
                    taskGoal: "Compile selected workspace records and artifacts into a concise report draft."
                ),
                WorkspaceAppActionSpec(
                    id: "export_report_runs",
                    type: "artifact.export",
                    label: "Export Report Runs",
                    table: "report_runs",
                    exportFormat: "json"
                )
            ],
            automations: [
                WorkspaceAppAutomationSpec(id: "weekly_report", type: "schedule", action: "draft_report_task")
            ],
            permissions: WorkspaceAppPermissions(
                reads: ["workspace.context", "task.artifacts", "appStorage.records"],
                writes: ["appStorage.records", "task.drafts"],
                defaultMode: idea.riskMode
            )
        )
    }

    private static func normalizedIntent(_ rawIntent: String) -> String {
        let trimmed = rawIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultIntent : trimmed
    }

    private static func title(from intent: String) -> String {
        let words = intent
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4)
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
        let title = words.joined(separator: " ")
        return title.isEmpty ? "Workspace App" : title
    }

    private static func slug(from title: String) -> String {
        let parts = title
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "workspace-app" : slug
    }
}

private struct WorkspaceAppStudioPatchError: Error, Equatable {
    var path: String
    var message: String
}

private enum WorkspaceAppStudioStructuredBlock: Equatable {
    case success(String)
    case notFound
    case failure(String)
}
