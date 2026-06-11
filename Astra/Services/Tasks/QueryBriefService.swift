import Foundation

enum QueryBriefRisk: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
    case unknown

    var displayName: String {
        switch self {
        case .low: "Low risk"
        case .medium: "Medium risk"
        case .high: "High risk"
        case .unknown: "Unknown risk"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? ""
        self = QueryBriefRisk(rawValue: raw) ?? .unknown
    }
}

enum QueryBriefCheckStatus: String, Codable, Equatable, Sendable {
    case passed
    case warning
    case blocked
    case info

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? ""
        self = QueryBriefCheckStatus(rawValue: raw) ?? .info
    }
}

struct QueryBriefTrustCheck: Identifiable, Codable, Equatable, Sendable {
    var id: String { "\(status.rawValue)-\(label)" }
    var status: QueryBriefCheckStatus
    var label: String
}

struct QueryBrief: Codable, Equatable, Sendable {
    var version: Int
    var goal: String
    var grain: String
    var tables: [String]
    var columns: [String]
    var filters: [String]
    var joins: [String]
    var assumptions: [String]
    var risk: QueryBriefRisk
    var estimatedCost: String
    var checks: [QueryBriefTrustCheck]
    var notes: [String]

    init(
        version: Int = 1,
        goal: String,
        grain: String = "",
        tables: [String] = [],
        columns: [String] = [],
        filters: [String] = [],
        joins: [String] = [],
        assumptions: [String] = [],
        risk: QueryBriefRisk = .unknown,
        estimatedCost: String = "",
        checks: [QueryBriefTrustCheck] = [],
        notes: [String] = []
    ) {
        self.version = version
        self.goal = goal
        self.grain = grain
        self.tables = tables
        self.columns = columns
        self.filters = filters
        self.joins = joins
        self.assumptions = assumptions
        self.risk = risk
        self.estimatedCost = estimatedCost
        self.checks = checks
        self.notes = notes
    }

    func normalized() -> QueryBrief {
        QueryBrief(
            version: version,
            goal: Self.limited(goal, fallback: "Review this SQL before execution."),
            grain: Self.limited(grain),
            tables: Self.limited(tables, maxCount: 10),
            columns: Self.limited(columns, maxCount: 12),
            filters: Self.limited(filters, maxCount: 10),
            joins: Self.limited(joins, maxCount: 8),
            assumptions: Self.limited(assumptions, maxCount: 10),
            risk: risk,
            estimatedCost: Self.limited(estimatedCost),
            checks: Self.limited(checks, maxCount: 10),
            notes: Self.limited(notes, maxCount: 8)
        )
    }

    private static func limited(_ value: String, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        guard resolved.count > 240 else { return resolved }
        return "\(resolved.prefix(237))..."
    }

    private static func limited(_ values: [String], maxCount: Int) -> [String] {
        Array(values
            .map { limited($0) }
            .filter { !$0.isEmpty }
            .prefix(maxCount))
    }

    private static func limited(_ values: [QueryBriefTrustCheck], maxCount: Int) -> [QueryBriefTrustCheck] {
        Array(values
            .map { QueryBriefTrustCheck(status: $0.status, label: limited($0.label)) }
            .filter { !$0.label.isEmpty }
            .prefix(maxCount))
    }
}

struct QueryBriefTaskContext: Equatable, Sendable {
    var taskTitle: String
    var taskGoal: String
    var workspaceName: String
}

struct QueryBriefRequest: Equatable, Sendable {
    var title: String
    var sql: String
    var connection: DatabaseConnection
    var dialect: SQLDialect
    var classification: QueryClassification
    var rowLimit: Int
    var dryRunResult: QueryDryRunResult?
    var schemaCatalog: SchemaCatalog?
    var taskContext: QueryBriefTaskContext?
}

protocol QueryBriefGenerating {
    func generateBrief(_ request: QueryBriefRequest) async throws -> QueryBrief
}

enum QueryBriefGenerationError: LocalizedError, Equatable {
    case emptySQL
    case providerFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .emptySQL:
            "Write or open SQL before generating an AI Brief."
        case .providerFailed(let message):
            "AI Brief failed: \(message)"
        case .invalidOutput(let message):
            "AI Brief returned data ASTRA could not read: \(message)"
        }
    }
}

struct AgentQueryBriefGenerator: QueryBriefGenerating {
    var workspacePath: String
    var utilityRuntime: AgentUtilityRuntimeConfiguration

    func generateBrief(_ request: QueryBriefRequest) async throws -> QueryBrief {
        let prompt = QueryBriefPromptBuilder.prompt(for: request)
        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: utilityRuntime,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            throw QueryBriefGenerationError.providerFailed("Exit code \(result.exitCode): \(result.failureDetail)")
        }

        guard let brief = QueryBriefParser.parse(from: result.output) else {
            throw QueryBriefGenerationError.invalidOutput(String(result.output.prefix(400)))
        }

        return brief.normalized()
    }
}

enum QueryBriefPromptBuilder {
    static func prompt(for request: QueryBriefRequest) -> String {
        let context = request.taskContext.map { task in
            """
            Task title: \(task.taskTitle)
            Task goal: \(task.taskGoal)
            Workspace: \(task.workspaceName)
            """
        } ?? "Task context: none"

        return """
        You are ASTRA's AI Brief generator for a SQL data shelf.
        Produce a concise pre-execution analysis brief for the current SQL.
        Do not run commands. Do not claim the query is correct unless the supplied dry-run context says it passed.

        Return exactly one structured line using this prefix and no markdown:
        ASTRA_QUERY_BRIEF {"version":1,"goal":"What the SQL is trying to answer","grain":"one row per ...","tables":["project.dataset.table"],"columns":["column"],"filters":["filter"],"joins":["join path"],"assumptions":["assumption"],"risk":"low|medium|high|unknown","estimatedCost":"cost or unknown","checks":[{"status":"passed|warning|blocked|info","label":"reason"}],"notes":["short note"]}

        Rules:
        - Keep every field short and user-verifiable.
        - If the task context and SQL disagree, mention that as an assumption or warning.
        - Include inferred grain when possible.
        - Include only tables, columns, joins, and filters that appear in the SQL or supplied schema context.
        - Use risk=high for DML, DDL, scripts, unknown classification, or expensive scans.
        - Use checks with concrete reasons, not a fake confidence number.

        Context:
        \(context)

        Query metadata:
        Title: \(request.title)
        Connection: \(request.connection.displayName)
        Dialect: \(request.dialect.displayName)
        Classification: \(request.classification.displayName)
        Row limit: \(request.rowLimit)
        Dry run: \(dryRunSummary(request.dryRunResult))

        Loaded schema context:
        \(schemaSummary(request.schemaCatalog))

        SQL:
        \(request.sql)
        """
    }

    private static func dryRunSummary(_ dryRun: QueryDryRunResult?) -> String {
        guard let dryRun else { return "not available" }
        if let bytes = dryRun.bytesProcessed {
            return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); \(dryRun.message)"
        }
        return dryRun.message
    }

    private static func schemaSummary(_ catalog: SchemaCatalog?) -> String {
        guard let catalog, !catalog.datasets.isEmpty else {
            return "No schema loaded in the shelf."
        }

        var lines: [String] = []
        for dataset in catalog.datasets.prefix(6) {
            lines.append("Dataset \(dataset.displayName):")
            for table in dataset.tables.prefix(12) {
                let columns = table.columns.prefix(10).map { "\($0.name):\($0.type)" }.joined(separator: ", ")
                if columns.isEmpty {
                    lines.append("- \(table.fullName) (\(table.type))")
                } else {
                    lines.append("- \(table.fullName) (\(table.type)): \(columns)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum QueryBriefParser {
    static func parse(from output: String) -> QueryBrief? {
        if let prefixed = prefixedPayload(in: output),
           let brief = decode(prefixed) {
            return brief
        }

        if let json = firstJSONObject(in: output),
           let brief = decode(json) {
            return brief
        }

        return nil
    }

    private static func prefixedPayload(in output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("ASTRA_QUERY_BRIEF") else { continue }
            return trimmed.replacingOccurrences(of: "ASTRA_QUERY_BRIEF", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func firstJSONObject(in output: String) -> String? {
        let characters = Array(output)
        guard let start = characters.firstIndex(of: "{") else { return nil }

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
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index])
                }
            }
        }
        return nil
    }

    private static func decode(_ payload: String) -> QueryBrief? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QueryBrief.self, from: data)
    }
}
