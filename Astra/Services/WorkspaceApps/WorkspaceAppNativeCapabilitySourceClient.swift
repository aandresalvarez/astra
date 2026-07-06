import Foundation
import ASTRAModels

protocol WorkspaceAppDatabaseQueryRunning {
    func run(_ request: QueryRequest) async throws -> QueryExecutionResult
}

extension DatabaseQueryService: WorkspaceAppDatabaseQueryRunning {}

struct WorkspaceAppNativeAsyncCapabilitySourceClient: WorkspaceAppAsyncCapabilitySourceClient {
    var queryRunner: any WorkspaceAppDatabaseQueryRunning = DatabaseQueryService()
    var redcapReader: any WorkspaceAppREDCapReading = WorkspaceAppUnavailableREDCapTransport()
    /// GitHub reads use the user's OWN ambient `gh` auth (no per-binding secret to wire), so unlike the
    /// REDCap reader this defaults to the REAL transport — a published `pullRequest.read` app shows live
    /// PRs out of the box. Tests inject a fake reader so the suite never shells out.
    var gitHubReader: any WorkspaceAppGitHubPRReading = WorkspaceAppGitHubCLIPRReader()

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        if requirement.contract == "tabularQuery.read",
           (binding.provider == "bigQuery" || requirement.providerHint == "bigQuery") {
            return try await WorkspaceAppBigQueryReadClient(queryRunner: queryRunner)
                .read(source: source, requirement: requirement, binding: binding, input: input)
        }
        if (requirement.contract == "recordProject.read" || requirement.contract == "formSchema.read"),
           (binding.provider == "redcap" || requirement.providerHint == "redcap") {
            return try await WorkspaceAppREDCapReadClient(reader: redcapReader)
                .read(source: source, requirement: requirement, binding: binding, input: input)
        }
        if requirement.contract == "pullRequest.read",
           (binding.provider == "github" || requirement.providerHint == "github") {
            return try await WorkspaceAppGitHubPRReadClient(reader: gitHubReader)
                .read(source: source, requirement: requirement, binding: binding, input: input)
        }
        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
    }
}

struct WorkspaceAppBigQueryReadClient: WorkspaceAppAsyncCapabilitySourceClient {
    var queryRunner: any WorkspaceAppDatabaseQueryRunning = DatabaseQueryService()
    var sqlBuilder = WorkspaceAppBigQueryReadSQLBuilder()

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        guard requirement.contract == "tabularQuery.read" else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
        }
        let operation = source.operation ?? requirement.operations.first ?? ""
        guard operation == "runReadOnlyQuery" || operation == "previewRows" else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        let sql = try sqlBuilder.sql(for: source, limit: input.limit)
        let result = try await queryRunner.run(QueryRequest(
            sql: sql,
            connection: connection(for: source, binding: binding),
            rowLimit: max(1, input.limit)
        ))
        return rows(from: result)
    }

    private func connection(
        for source: WorkspaceAppSource,
        binding: WorkspaceAppDependencyBinding
    ) -> DatabaseConnection {
        DatabaseConnection(
            id: binding.implementationID ?? "bigquery-cli",
            displayName: binding.provider ?? "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: sqlBuilder.datasetID(from: source.tableRef),
            projectID: source.projectRef
        )
    }

    private func rows(from result: QueryExecutionResult) -> [[String: WorkspaceAppStorageValue]] {
        result.rows.map { row in
            var values: [String: WorkspaceAppStorageValue] = [:]
            for (index, column) in result.columns.enumerated() where index < row.count {
                values[column.name] = .text(row[index])
            }
            return values
        }
    }
}

struct WorkspaceAppBigQueryReadSQLBuilder {
    func sql(
        for source: WorkspaceAppSource,
        limit: Int
    ) throws -> String {
        if let query = source.query?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        guard let table = source.tableRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !table.isEmpty,
              let quotedTable = quotedTableIdentifier(table, projectRef: source.projectRef) else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        return "SELECT * FROM \(quotedTable) LIMIT \(max(1, limit))"
    }

    private func quotedTableIdentifier(_ tableRef: String, projectRef: String?) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.:")
        guard tableRef.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let table = tableRef.replacingOccurrences(of: ":", with: ".")
        if table.split(separator: ".").count == 2,
           let projectRef,
           !projectRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let projectAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            guard projectRef.unicodeScalars.allSatisfy({ projectAllowed.contains($0) }) else { return nil }
            return "`\(projectRef).\(table)`"
        }
        return "`\(table)`"
    }

    func datasetID(from tableRef: String?) -> String? {
        guard let tableRef else { return nil }
        let parts = tableRef.replacingOccurrences(of: ":", with: ".").split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }
}

struct WorkspaceAppREDCapRequest: Sendable, Equatable {
    var operation: String
    var projectRef: String?
    var sourceID: String?
    var parameters: [String: WorkspaceAppStorageValue]
    var record: [String: WorkspaceAppStorageValue]
}

protocol WorkspaceAppREDCapReading {
    func read(_ request: WorkspaceAppREDCapRequest) async throws -> [[String: WorkspaceAppStorageValue]]
}

protocol WorkspaceAppREDCapWriting {
    func write(_ request: WorkspaceAppREDCapRequest) throws -> WorkspaceAppCapabilityWriteResult
}

struct WorkspaceAppUnavailableREDCapTransport: WorkspaceAppREDCapReading, WorkspaceAppREDCapWriting {
    func read(_ request: WorkspaceAppREDCapRequest) async throws -> [[String: WorkspaceAppStorageValue]] {
        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(request.sourceID ?? request.operation)
    }

    func write(_ request: WorkspaceAppREDCapRequest) throws -> WorkspaceAppCapabilityWriteResult {
        throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(request.operation)
    }
}

struct WorkspaceAppREDCapReadClient: WorkspaceAppAsyncCapabilitySourceClient {
    var reader: any WorkspaceAppREDCapReading = WorkspaceAppUnavailableREDCapTransport()

    func read(
        source: WorkspaceAppSource,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        guard binding.provider == "redcap" || requirement.providerHint == "redcap" else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable(source.id)
        }
        let operation = source.operation ?? requirement.operations.first ?? ""
        guard supportedOperations(for: requirement.contract).contains(operation) else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(source.id)
        }
        return try await reader.read(WorkspaceAppREDCapRequest(
            operation: operation,
            projectRef: source.projectRef,
            sourceID: source.id,
            parameters: input.parameters,
            record: [:]
        ))
    }

    private func supportedOperations(for contract: String) -> Set<String> {
        switch contract {
        case "recordProject.read":
            return ["describeProject", "listForms", "listFields", "readRecords", "lookupRecord", "validateRecord"]
        case "formSchema.read":
            return ["describeForms", "describeFields", "describeBranchingRules"]
        default:
            return []
        }
    }
}

/// Async capability-write client — the path `WorkspaceAppActionExecutor.executeAsync` uses for the
/// one action type that needs real network I/O (capability.write submit). REDCap prepare/validate
/// stay synthetic (no network); submitCreate/submitUpdate perform the REAL REDCap import via a
/// transport resolved for the binding. A nil transport (no connector configured) throws
/// capabilityWriteUnavailable — same refusal as the sync stub, never a silent fake.
protocol WorkspaceAppAsyncCapabilityWriteClient {
    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) async throws -> WorkspaceAppCapabilityWriteResult
}

struct WorkspaceAppNativeAsyncCapabilityWriteClient: WorkspaceAppAsyncCapabilityWriteClient {
    /// Resolves a configured REDCap HTTP transport (endpoint + token) for a binding. Default returns
    /// nil — until a connector is configured, submits cleanly refuse rather than pretend.
    var redcapTransport: (WorkspaceAppDependencyBinding) -> WorkspaceAppREDCapHTTPTransport? = { _ in nil }

    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) async throws -> WorkspaceAppCapabilityWriteResult {
        guard requirement.contract == "recordProject.write",
              binding.provider == "redcap" || requirement.providerHint == "redcap" else {
            throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(action.id)
        }
        let operation = action.operation ?? requirement.operations.first ?? ""
        switch operation {
        case "prepareCreate", "prepareUpdate":
            return WorkspaceAppCapabilityWriteResult(
                outputSummary: "Prepared REDCap \(operation == "prepareCreate" ? "create" : "update") draft with \(input.record.count) fields.",
                rows: [input.record]
            )
        case "validateWrite":
            return WorkspaceAppCapabilityWriteResult(
                outputSummary: "Validated REDCap write draft with \(input.record.count) fields.",
                rows: [["status": .text("valid"), "fieldCount": .integer(Int64(input.record.count))]]
            )
        case "submitCreate", "submitUpdate":
            guard let transport = redcapTransport(binding) else {
                throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(action.id)
            }
            return try await transport.submit(record: input.record)
        default:
            throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(action.id)
        }
    }
}

struct WorkspaceAppNativeCapabilityWriteClient: WorkspaceAppCapabilityWriteClient {
    var redcapWriter: any WorkspaceAppREDCapWriting = WorkspaceAppUnavailableREDCapTransport()

    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) throws -> WorkspaceAppCapabilityWriteResult {
        if requirement.contract == "recordProject.write",
           (binding.provider == "redcap" || requirement.providerHint == "redcap") {
            return try WorkspaceAppREDCapWriteClient(writer: redcapWriter)
                .write(action: action, requirement: requirement, binding: binding, input: input)
        }
        throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(action.id)
    }
}

struct WorkspaceAppREDCapWriteClient: WorkspaceAppCapabilityWriteClient {
    var writer: any WorkspaceAppREDCapWriting = WorkspaceAppUnavailableREDCapTransport()

    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) throws -> WorkspaceAppCapabilityWriteResult {
        guard requirement.contract == "recordProject.write",
              binding.provider == "redcap" || requirement.providerHint == "redcap" else {
            throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(action.id)
        }
        let operation = action.operation ?? requirement.operations.first ?? ""
        guard ["prepareCreate", "prepareUpdate", "validateWrite", "submitCreate", "submitUpdate"].contains(operation) else {
            throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(action.id)
        }
        let request = WorkspaceAppREDCapRequest(
            operation: operation,
            projectRef: action.sourceRef,
            sourceID: nil,
            parameters: [:],
            record: input.record
        )
        switch operation {
        case "prepareCreate", "prepareUpdate":
            return WorkspaceAppCapabilityWriteResult(
                outputSummary: "Prepared REDCap \(operation == "prepareCreate" ? "create" : "update") draft with \(input.record.count) fields.",
                rows: [input.record]
            )
        case "validateWrite":
            return WorkspaceAppCapabilityWriteResult(
                outputSummary: "Validated REDCap write draft with \(input.record.count) fields.",
                rows: [["status": .text("valid"), "fieldCount": .integer(Int64(input.record.count))]]
            )
        default:
            return try writer.write(request)
        }
    }
}
