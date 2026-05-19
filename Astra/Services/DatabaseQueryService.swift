import Foundation
import ASTRACore

enum SQLDialect: String, CaseIterable, Identifiable, Codable, Sendable {
    case bigQueryStandard
    case postgres
    case snowflake
    case duckDB
    case sqlite
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bigQueryStandard: "BigQuery Standard SQL"
        case .postgres: "Postgres"
        case .snowflake: "Snowflake"
        case .duckDB: "DuckDB"
        case .sqlite: "SQLite"
        case .unknown: "SQL"
        }
    }
}

enum QueryClassification: String, CaseIterable, Identifiable, Codable, Sendable {
    case read
    case ddl
    case dml
    case script
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .read: "Read query"
        case .ddl: "DDL"
        case .dml: "DML"
        case .script: "Script"
        case .unknown: "Unknown"
        }
    }

    var requiresRecovery: Bool {
        switch self {
        case .read: false
        case .ddl, .dml, .script, .unknown: true
        }
    }
}

enum QueryExecutionStatus: String, Codable, Sendable {
    case draft
    case dryRunSucceeded
    case succeeded
    case failed
    case blocked
}

struct DatabaseConnection: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var displayName: String
    var adapterID: String
    var dialect: SQLDialect
    var defaultNamespace: String?
    var projectID: String?

    static let editOnly = DatabaseConnection(
        id: "edit-only",
        displayName: "No connection / Edit only",
        adapterID: "edit-only",
        dialect: .unknown,
        defaultNamespace: nil,
        projectID: nil
    )
}

struct QueryRequest: Sendable {
    var sql: String
    var connection: DatabaseConnection
    var rowLimit: Int
}

struct SchemaRequest: Sendable {
    var connection: DatabaseConnection
    var datasetID: String?
    var sqlContext: String = ""
}

struct SchemaTableRequest: Sendable {
    var connection: DatabaseConnection
    var projectID: String?
    var datasetID: String
    var tableID: String
}

struct QueryDryRunResult: Codable, Equatable, Sendable {
    var bytesProcessed: Int64?
    var message: String
    var jobID: String?
}

struct QueryResultColumn: Identifiable, Codable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let type: String
}

struct QueryExecutionResult: Codable, Equatable, Sendable {
    var columns: [QueryResultColumn]
    var rows: [[String]]
    var rowCount: Int
    var bytesProcessed: Int64?
    var elapsedMilliseconds: Int?
    var jobID: String?
    var message: String
}

struct SchemaCatalog: Equatable, Sendable {
    var datasets: [SchemaDataset]
}

struct SchemaDataset: Identifiable, Equatable, Sendable {
    var id: String { datasetID }
    var datasetID: String
    var displayName: String
    var tables: [SchemaTable]
}

struct SchemaTable: Identifiable, Equatable, Sendable {
    var id: String { fullName }
    var projectID: String?
    var datasetID: String
    var tableID: String
    var fullName: String
    var type: String
    var columns: [SchemaColumn]
}

struct SchemaColumn: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var type: String
    var mode: String?
}

struct RecoveryPlan: Codable, Equatable, Sendable {
    var title: String
    var details: String
    var restoreSQL: String
    var isPrepared: Bool
    var sourceTableID: String? = nil
    var backupTableID: String? = nil
}

struct QueryHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var sql: String
    var connectionName: String
    var dialect: SQLDialect
    var classification: QueryClassification
    var status: QueryExecutionStatus
    var createdAt: Date
    var dryRun: QueryDryRunResult?
    var result: QueryExecutionResult?
    var recoveryPlan: RecoveryPlan?
    var errorMessage: String?

    init(
        sql: String,
        connectionName: String,
        dialect: SQLDialect,
        classification: QueryClassification,
        status: QueryExecutionStatus,
        dryRun: QueryDryRunResult? = nil,
        result: QueryExecutionResult? = nil,
        recoveryPlan: RecoveryPlan? = nil,
        errorMessage: String? = nil
    ) {
        id = UUID()
        self.sql = sql
        self.connectionName = connectionName
        self.dialect = dialect
        self.classification = classification
        self.status = status
        createdAt = Date()
        self.dryRun = dryRun
        self.result = result
        self.recoveryPlan = recoveryPlan
        self.errorMessage = errorMessage
    }
}

enum SQLClassifier {
    static func classify(_ sql: String) -> QueryClassification {
        let normalized = stripLeadingComments(sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return .unknown }

        let statements = normalized
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if statements.count > 1 { return .script }

        let first = statements.first ?? normalized
        if first.hasPrefix("select") || first.hasPrefix("with") { return .read }
        if first.hasPrefix("insert") || first.hasPrefix("update") || first.hasPrefix("delete") ||
            first.hasPrefix("merge") || first.hasPrefix("truncate") {
            return .dml
        }
        if first.hasPrefix("create") || first.hasPrefix("alter") || first.hasPrefix("drop") {
            return .ddl
        }
        if first.contains("\nbegin") || first.hasPrefix("begin") { return .script }
        return .unknown
    }

    private static func stripLeadingComments(_ sql: String) -> String {
        var lines = sql.components(separatedBy: .newlines)
        while let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first.hasPrefix("--") || first.isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}

protocol DatabaseAdapter {
    var id: String { get }
    var displayName: String { get }
    func dryRun(_ request: QueryRequest) async throws -> QueryDryRunResult
    func run(_ request: QueryRequest) async throws -> QueryExecutionResult
    func schema(_ request: SchemaRequest) async throws -> SchemaCatalog
    func tableSchema(_ request: SchemaTableRequest) async throws -> SchemaTable
    func prepareRecovery(_ request: QueryRequest, classification: QueryClassification) async throws -> RecoveryPlan
}

protocol StandardInputBinaryRunner: BinaryRunner {
    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        standardInput: String
    ) async -> RunResult
}

enum DatabaseQueryError: LocalizedError {
    case editOnly
    case missingExecutable(String)
    case blockedMutation(String)
    case commandFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .editOnly:
            "Choose a database connection before running SQL."
        case .missingExecutable(let executable):
            if executable == "bq" {
                "BigQuery CLI (`bq`) was not found. Install the Google Cloud SDK, make sure `bq` is on PATH, then retry."
            } else {
                "\(executable) is not installed or could not be found."
            }
        case .blockedMutation(let message):
            message
        case .commandFailed(let message):
            message
        case .invalidOutput(let message):
            message
        }
    }
}

struct BigQueryCLIAdapter: DatabaseAdapter {
    let id = "bigquery-cli"
    let displayName = "BigQuery CLI"

    private let runner: BinaryRunner
    private let inputRunner: StandardInputBinaryRunner?
    private let bqPathOverride: String?
    private let executableResolver: @Sendable () -> String

    init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        bqPath: String? = nil,
        executableResolver: @escaping @Sendable () -> String = {
            RuntimePathResolver.detectExecutablePath(named: "bq")
        }
    ) {
        self.runner = runner
        self.inputRunner = runner as? StandardInputBinaryRunner
        self.bqPathOverride = bqPath
        self.executableResolver = executableResolver
    }

    func dryRun(_ request: QueryRequest) async throws -> QueryDryRunResult {
        let bqPath = try resolvedExecutablePath()
        let result = await runQuery(
            request,
            bqPath: bqPath,
            args: baseArgs(for: request.connection) + [
                "query",
                "--use_legacy_sql=false",
                "--dry_run"
            ],
            timeout: 30
        )
        guard result.isSuccess else {
            throw DatabaseQueryError.commandFailed(commandMessage(result))
        }
        let combined = [result.stdout, result.stderr].joined(separator: "\n")
        let message = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return QueryDryRunResult(
            bytesProcessed: parseBytesProcessed(from: combined),
            message: message.isEmpty ? "Dry run succeeded." : message,
            jobID: parseJobID(from: combined)
        )
    }

    func run(_ request: QueryRequest) async throws -> QueryExecutionResult {
        let bqPath = try resolvedExecutablePath()
        let start = Date()
        let result = await runQuery(
            request,
            bqPath: bqPath,
            args: baseArgs(for: request.connection) + [
                "query",
                "--use_legacy_sql=false",
                "--format=json",
                "--max_rows=\(request.rowLimit)"
            ],
            timeout: 120
        )
        guard result.isSuccess else {
            throw DatabaseQueryError.commandFailed(commandMessage(result))
        }
        let rows = try parseJSONRows(result.stdout)
        let columns = columns(from: rows)
        return QueryExecutionResult(
            columns: columns,
            rows: rows.map { row in columns.map { row[$0.name] ?? "" } },
            rowCount: rows.count,
            bytesProcessed: parseBytesProcessed(from: result.stderr),
            elapsedMilliseconds: Int(Date().timeIntervalSince(start) * 1000),
            jobID: parseJobID(from: [result.stdout, result.stderr].joined(separator: "\n")),
            message: rows.isEmpty ? "Query completed with no preview rows." : "Query completed."
        )
    }

    func schema(_ request: SchemaRequest) async throws -> SchemaCatalog {
        let bqPath = try resolvedExecutablePath()
        let datasetIDs = try await requestedDatasetIDs(request, bqPath: bqPath)
        var datasets: [SchemaDataset] = []
        for datasetID in datasetIDs {
            let tables = try await listTables(connection: request.connection, datasetID: datasetID, bqPath: bqPath)
            datasets.append(SchemaDataset(
                datasetID: datasetID,
                displayName: datasetID,
                tables: tables
            ))
        }
        return SchemaCatalog(datasets: datasets)
    }

    func tableSchema(_ request: SchemaTableRequest) async throws -> SchemaTable {
        let bqPath = try resolvedExecutablePath()
        let tableSpec = tableSpec(
            projectID: request.projectID ?? request.connection.projectID,
            datasetID: request.datasetID,
            tableID: request.tableID
        )
        let result = await runner.run(
            path: bqPath,
            args: baseArgs(for: request.connection) + ["show", "--format=json", tableSpec],
            timeout: 30,
            environment: nil
        )
        guard result.isSuccess else {
            throw DatabaseQueryError.commandFailed(commandMessage(result))
        }
        let columns = try parseColumns(from: result.stdout)
        return SchemaTable(
            projectID: request.projectID ?? request.connection.projectID,
            datasetID: request.datasetID,
            tableID: request.tableID,
            fullName: tableSpec,
            type: "TABLE",
            columns: columns
        )
    }

    private func runQuery(_ request: QueryRequest, bqPath: String, args: [String], timeout: TimeInterval) async -> RunResult {
        if let inputRunner {
            return await inputRunner.run(
                path: bqPath,
                args: args,
                timeout: timeout,
                environment: nil,
                standardInput: request.sql
            )
        }

        let sql = request.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        return await runner.run(
            path: bqPath,
            args: args + [sql],
            timeout: timeout,
            environment: nil
        )
    }

    func prepareRecovery(_ request: QueryRequest, classification: QueryClassification) async throws -> RecoveryPlan {
        let bqPath = try resolvedExecutablePath()
        if classification == .read {
            return RecoveryPlan(
                title: "No recovery required",
                details: "Read-only queries do not mutate database state.",
                restoreSQL: "",
                isPrepared: true
            )
        }

        let backupSuffix = DateFormatter.queryBackupSuffix.string(from: Date())
        if classification == .ddl,
           let createTarget = SQLTableReferenceExtractor.createTableTarget(from: request.sql),
           !SQLTableReferenceExtractor.isReplaceOrDropStyleDDL(request.sql) {
            let source = normalizedTableReference(createTarget, connection: request.connection)
            return RecoveryPlan(
                title: "New table recovery prepared",
                details: "This DDL appears to create a new table. Recovery is a DROP TABLE statement for the created table.",
                restoreSQL: "DROP TABLE `\(source.sqlName)`;",
                isPrepared: true,
                sourceTableID: source.sqlName,
                backupTableID: nil
            )
        }

        guard let affected = SQLTableReferenceExtractor.firstMutatedTable(from: request.sql) else {
            let details = """
            ASTRA could not identify the affected BigQuery table automatically.
            Split the statement to a single DML/DDL query or create a backup manually before running.
            Suggested suffix: __astra_backup_\(backupSuffix)
            """
            return RecoveryPlan(
                title: "Manual recovery required",
                details: details,
                restoreSQL: "-- Restore manually after creating a verified backup for the affected table.",
                isPrepared: false
            )
        }

        let source = normalizedTableReference(affected, connection: request.connection)
        let backup = source.backup(suffix: "__astra_backup_\(backupSuffix)")
        let result = await runner.run(
            path: bqPath,
            args: baseArgs(for: request.connection) + ["cp", source.bqSpec, backup.bqSpec],
            timeout: 120,
            environment: nil
        )
        guard result.isSuccess else {
            throw DatabaseQueryError.commandFailed(commandMessage(result))
        }

        let details = """
        BigQuery backup created before mutation.
        Source: \(source.sqlName)
        Backup: \(backup.sqlName)
        """
        return RecoveryPlan(
            title: "BigQuery backup prepared",
            details: details,
            restoreSQL: "CREATE OR REPLACE TABLE `\(source.sqlName)` AS SELECT * FROM `\(backup.sqlName)`;",
            isPrepared: true,
            sourceTableID: source.sqlName,
            backupTableID: backup.sqlName
        )
    }

    private func resolvedExecutablePath() throws -> String {
        let candidate = bqPathOverride ?? executableResolver()
        guard !candidate.isEmpty,
              FileManager.default.isExecutableFile(atPath: candidate) else {
            throw DatabaseQueryError.missingExecutable("bq")
        }
        return candidate
    }

    private func baseArgs(for connection: DatabaseConnection) -> [String] {
        if let projectID = connection.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return ["--project_id=\(projectID)"]
        }
        return []
    }

    private func requestedDatasetIDs(_ request: SchemaRequest, bqPath: String) async throws -> [String] {
        if let datasetID = request.datasetID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !datasetID.isEmpty {
            return [datasetID]
        }
        let referencedDatasets = SQLTableReferenceExtractor.datasetReferences(
            from: request.sqlContext,
            defaultProjectID: request.connection.projectID
        )
        if !referencedDatasets.isEmpty {
            return referencedDatasets
        }
        if let namespace = request.connection.defaultNamespace?.trimmingCharacters(in: .whitespacesAndNewlines),
           !namespace.isEmpty {
            return [namespace]
        }

        let result = await runner.run(
            path: bqPath,
            args: baseArgs(for: request.connection) + ["ls", "--format=json"],
            timeout: 30,
            environment: nil
        )
        guard result.isSuccess else {
            throw DatabaseQueryError.commandFailed(commandMessage(result))
        }
        return try parseDatasetIDs(from: result.stdout)
    }

    private func listTables(connection: DatabaseConnection, datasetID: String, bqPath: String) async throws -> [SchemaTable] {
        let datasetSpec = datasetSpec(connection: connection, datasetID: datasetID)
        let result = await runner.run(
            path: bqPath,
            args: baseArgs(for: connection) + ["ls", "--format=json", datasetSpec],
            timeout: 30,
            environment: nil
        )
        guard result.isSuccess else {
            throw DatabaseQueryError.commandFailed(commandMessage(result))
        }
        return try parseTables(from: result.stdout, connection: connection, fallbackDatasetID: datasetID)
    }

    private func parseDatasetIDs(from output: String) throws -> [String] {
        let objects = try parseJSONArray(from: output, description: "dataset metadata")
        return objects.compactMap { object in
            if let reference = object["datasetReference"] as? [String: Any],
               let datasetID = reference["datasetId"] as? String {
                return datasetID
            }
            if let id = object["id"] as? String {
                return id.components(separatedBy: ":").last
            }
            return nil
        }
        .sorted()
    }

    private func parseTables(
        from output: String,
        connection: DatabaseConnection,
        fallbackDatasetID: String
    ) throws -> [SchemaTable] {
        let objects = try parseJSONArray(from: output, description: "table metadata")
        return objects.compactMap { object in
            guard let reference = object["tableReference"] as? [String: Any],
                  let tableID = reference["tableId"] as? String else {
                return nil
            }
            let datasetID = (reference["datasetId"] as? String) ?? fallbackDatasetID
            let projectID = (reference["projectId"] as? String) ?? connection.projectID
            let type = (object["type"] as? String) ?? "TABLE"
            return SchemaTable(
                projectID: projectID,
                datasetID: datasetID,
                tableID: tableID,
                fullName: tableSpec(projectID: projectID, datasetID: datasetID, tableID: tableID),
                type: type,
                columns: []
            )
        }
        .sorted { $0.tableID.localizedStandardCompare($1.tableID) == .orderedAscending }
    }

    private func parseColumns(from output: String) throws -> [SchemaColumn] {
        let payload = try jsonPayload(from: output, opening: "{", closing: "}", description: "table schema")
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DatabaseQueryError.invalidOutput("BigQuery returned table schema that was not JSON. Output: \(snippet(output))")
        }
        guard let schema = object["schema"] as? [String: Any],
              let fields = schema["fields"] as? [[String: Any]] else {
            return []
        }
        return fields.compactMap { field in
            guard let name = field["name"] as? String else { return nil }
            return SchemaColumn(
                name: name,
                type: (field["type"] as? String) ?? "STRING",
                mode: field["mode"] as? String
            )
        }
    }

    private func parseJSONArray(from output: String, description: String) throws -> [[String: Any]] {
        let payload = try jsonPayload(from: output, opening: "[", closing: "]", description: description)
        guard let data = payload.data(using: .utf8),
              let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DatabaseQueryError.invalidOutput("BigQuery returned \(description) that was not a JSON array. Output: \(snippet(output))")
        }
        return objects
    }

    private func jsonPayload(from output: String, opening: Character, closing: Character, description: String) throws -> String {
        let characters = Array(output)
        guard let start = characters.firstIndex(of: opening) else {
            throw DatabaseQueryError.invalidOutput("BigQuery returned \(description) without a JSON payload. Output: \(snippet(output))")
        }

        var depth = 0
        var isInString = false
        var isEscaped = false
        for index in start..<characters.endIndex {
            let character = characters[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            if character == "\"" {
                isInString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index])
                }
            }
        }

        throw DatabaseQueryError.invalidOutput("BigQuery returned incomplete \(description) JSON. Output: \(snippet(output))")
    }

    private func snippet(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 400 else { return trimmed.isEmpty ? "<empty>" : trimmed }
        return "\(trimmed.prefix(400))..."
    }

    private func tableSpec(projectID: String?, datasetID: String, tableID: String) -> String {
        if let projectID, !projectID.isEmpty {
            return "\(projectID):\(datasetID).\(tableID)"
        }
        return "\(datasetID).\(tableID)"
    }

    private func datasetSpec(connection: DatabaseConnection, datasetID: String) -> String {
        if datasetID.contains(":") {
            return datasetID
        }
        if let projectID = connection.projectID, !projectID.isEmpty {
            return "\(projectID):\(datasetID)"
        }
        return datasetID
    }

    private func normalizedTableReference(_ raw: String, connection: DatabaseConnection) -> BigQueryTableReference {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        let parts = cleaned.split(separator: ".").map(String.init)
        if parts.count >= 3 {
            return BigQueryTableReference(projectID: parts[parts.count - 3], datasetID: parts[parts.count - 2], tableID: parts[parts.count - 1])
        }
        if parts.count == 2 {
            return BigQueryTableReference(projectID: connection.projectID, datasetID: parts[0], tableID: parts[1])
        }
        return BigQueryTableReference(projectID: connection.projectID, datasetID: connection.defaultNamespace ?? "", tableID: cleaned)
    }

    private func commandMessage(_ result: RunResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        return "BigQuery command failed."
    }

    private func parseJSONRows(_ output: String) throws -> [[String: String]] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DatabaseQueryError.invalidOutput("BigQuery returned output that was not a JSON row array.")
        }
        return objects.map { object in
            object.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
        }
    }

    private func columns(from rows: [[String: String]]) -> [QueryResultColumn] {
        let names = rows.flatMap(\.keys).reduce(into: [String]()) { result, key in
            if !result.contains(key) { result.append(key) }
        }
        return names.map { QueryResultColumn(name: $0, type: "STRING") }
    }

    private func parseBytesProcessed(from text: String) -> Int64? {
        let patterns = [
            #"process\s+([0-9,]+)\s+bytes"#,
            #"totalBytesProcessed["']?\s*[:=]\s*["']?([0-9]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsText = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
                  match.numberOfRanges > 1 else {
                continue
            }
            let raw = nsText.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            if let value = Int64(raw) { return value }
        }
        return nil
    }

    private func parseJobID(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"job[_ ]?id[:=]\s*([A-Za-z0-9_\-:.]+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }
}

struct DatabaseQueryService {
    var adapters: [String: DatabaseAdapter] = [
        "bigquery-cli": BigQueryCLIAdapter()
    ]

    func dryRun(_ request: QueryRequest) async throws -> QueryDryRunResult {
        try await adapter(for: request.connection).dryRun(request)
    }

    func run(_ request: QueryRequest) async throws -> QueryExecutionResult {
        try await adapter(for: request.connection).run(request)
    }

    func schema(_ request: SchemaRequest) async throws -> SchemaCatalog {
        try await adapter(for: request.connection).schema(request)
    }

    func tableSchema(_ request: SchemaTableRequest) async throws -> SchemaTable {
        try await adapter(for: request.connection).tableSchema(request)
    }

    func prepareRecovery(_ request: QueryRequest, classification: QueryClassification) async throws -> RecoveryPlan {
        try await adapter(for: request.connection).prepareRecovery(request, classification: classification)
    }

    private func adapter(for connection: DatabaseConnection) throws -> DatabaseAdapter {
        guard connection.id != DatabaseConnection.editOnly.id else {
            throw DatabaseQueryError.editOnly
        }
        guard let adapter = adapters[connection.adapterID] else {
            throw DatabaseQueryError.commandFailed("No adapter is available for \(connection.displayName).")
        }
        return adapter
    }
}

extension ProcessBinaryRunner: StandardInputBinaryRunner {
    public func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        standardInput: String
    ) async -> RunResult {
        await withCheckedContinuation { continuation in
            let state = QueryProcessContinuationState(continuation: continuation)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            if let environment {
                process.environment = environment
            }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutCollector = QueryProcessPipeCollector()
            let stderrCollector = QueryProcessPipeCollector()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stdoutCollector.append(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stderrCollector.append(data)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !tailOut.isEmpty {
                    stdoutCollector.append(tailOut)
                }
                let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !tailErr.isEmpty {
                    stderrCollector.append(tailErr)
                }

                state.finish(
                    outcome: .exited(code: proc.terminationStatus),
                    stdout: stdoutCollector.string,
                    stderr: stderrCollector.string
                )
            }

            do {
                try process.run()
                if let data = standardInput.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                state.finish(
                    outcome: .launchFailed(error.localizedDescription),
                    stdout: "",
                    stderr: ""
                )
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard process.isRunning else { return }
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                state.finish(
                    outcome: .timedOut,
                    stdout: stdoutCollector.string,
                    stderr: stderrCollector.string
                )
            }
        }
    }
}

private final class QueryProcessPipeCollector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

private final class QueryProcessContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RunResult, Never>?

    init(continuation: CheckedContinuation<RunResult, Never>) {
        self.continuation = continuation
    }

    func finish(outcome: RunResult.Outcome, stdout: String, stderr: String) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: RunResult(outcome: outcome, stdout: stdout, stderr: stderr))
    }
}

private struct BigQueryTableReference: Equatable {
    var projectID: String?
    var datasetID: String
    var tableID: String

    var bqSpec: String {
        if let projectID, !projectID.isEmpty {
            return "\(projectID):\(datasetID).\(tableID)"
        }
        return "\(datasetID).\(tableID)"
    }

    var sqlName: String {
        if let projectID, !projectID.isEmpty {
            return "\(projectID).\(datasetID).\(tableID)"
        }
        return "\(datasetID).\(tableID)"
    }

    func backup(suffix: String) -> BigQueryTableReference {
        BigQueryTableReference(projectID: projectID, datasetID: datasetID, tableID: "\(tableID)\(suffix)")
    }
}

enum SQLTableReferenceExtractor {
    static func datasetReferences(from sql: String, defaultProjectID: String?) -> [String] {
        let tablePatterns = [
            #"(?is)\bfrom\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bjoin\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bupdate\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bdelete\s+from\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bmerge\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\binsert\s+into\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#
        ]
        var datasets: [String] = []
        let nsSQL = sql as NSString
        for pattern in tablePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: sql, range: NSRange(location: 0, length: nsSQL.length))
            for match in matches where match.numberOfRanges > 1 {
                let raw = nsSQL.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                guard let dataset = datasetReference(fromTableName: raw, defaultProjectID: defaultProjectID),
                      !datasets.contains(dataset) else {
                    continue
                }
                datasets.append(dataset)
            }
        }
        return datasets
    }

    static func firstMutatedTable(from sql: String) -> String? {
        let patterns = [
            #"(?is)\bupdate\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bdelete\s+from\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bmerge\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\binsert\s+into\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\btruncate\s+table\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\balter\s+table\s+(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bdrop\s+table\s+(?:if\s+exists\s+)?(`[^`]+`|[A-Za-z0-9_\-:.]+)"#,
            #"(?is)\bcreate\s+(?:or\s+replace\s+)?table\s+(?:if\s+not\s+exists\s+)?(`[^`]+`|[A-Za-z0-9_\-:.]+)"#
        ]
        return firstMatch(in: sql, patterns: patterns)
    }

    static func createTableTarget(from sql: String) -> String? {
        firstMatch(in: sql, patterns: [
            #"(?is)\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?(`[^`]+`|[A-Za-z0-9_\-:.]+)"#
        ])
    }

    static func isReplaceOrDropStyleDDL(_ sql: String) -> Bool {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("create or replace") ||
            normalized.hasPrefix("drop ") ||
            normalized.hasPrefix("alter ")
    }

    private static func firstMatch(in sql: String, patterns: [String]) -> String? {
        let nsSQL = sql as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            guard let match = regex.firstMatch(in: sql, range: NSRange(location: 0, length: nsSQL.length)),
                  match.numberOfRanges > 1 else {
                continue
            }
            return nsSQL.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        return nil
    }

    private static func datasetReference(fromTableName raw: String, defaultProjectID: String?) -> String? {
        let normalized = raw.replacingOccurrences(of: ":", with: ".")
        let parts = normalized.split(separator: ".").map(String.init)
        if parts.count >= 3 {
            return "\(parts[parts.count - 3]):\(parts[parts.count - 2])"
        }
        if parts.count == 2 {
            if let defaultProjectID, !defaultProjectID.isEmpty {
                return "\(defaultProjectID):\(parts[0])"
            }
            return parts[0]
        }
        return nil
    }
}

private extension DateFormatter {
    static let queryBackupSuffix: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}
