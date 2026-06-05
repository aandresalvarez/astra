import Foundation

struct QueryResultExplanation: Codable, Equatable, Sendable {
    var version: Int
    var headline: String
    var summary: String
    var keyFindings: [String]
    var anomalies: [String]
    var caveats: [String]
    var followUps: [String]
    var checks: [QueryBriefTrustCheck]

    init(
        version: Int = 1,
        headline: String,
        summary: String = "",
        keyFindings: [String] = [],
        anomalies: [String] = [],
        caveats: [String] = [],
        followUps: [String] = [],
        checks: [QueryBriefTrustCheck] = []
    ) {
        self.version = version
        self.headline = headline
        self.summary = summary
        self.keyFindings = keyFindings
        self.anomalies = anomalies
        self.caveats = caveats
        self.followUps = followUps
        self.checks = checks
    }

    func normalized() -> QueryResultExplanation {
        QueryResultExplanation(
            version: version,
            headline: Self.limited(headline, fallback: "Result explanation"),
            summary: Self.limited(summary),
            keyFindings: Self.limited(keyFindings, maxCount: 8),
            anomalies: Self.limited(anomalies, maxCount: 6),
            caveats: Self.limited(caveats, maxCount: 6),
            followUps: Self.limited(followUps, maxCount: 6),
            checks: Self.limited(checks, maxCount: 8)
        )
    }

    private static func limited(_ value: String, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        guard resolved.count > 300 else { return resolved }
        return "\(resolved.prefix(297))..."
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

struct QueryResultExplanationRequest: Equatable, Sendable {
    var title: String
    var sql: String
    var connection: DatabaseConnection
    var dialect: SQLDialect
    var rowLimit: Int
    var dryRunResult: QueryDryRunResult?
    var executionResult: QueryExecutionResult
    var schemaCatalog: SchemaCatalog?
    var taskContext: QueryBriefTaskContext?
    var brief: QueryBrief?
}

protocol QueryResultExplanationGenerating {
    func explainResult(_ request: QueryResultExplanationRequest) async throws -> QueryResultExplanation
}

enum QueryResultExplanationError: LocalizedError, Equatable {
    case noResult
    case emptySQL
    case providerFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .noResult:
            "Run a query before asking AI to explain the result."
        case .emptySQL:
            "Write or open SQL before asking AI to explain the result."
        case .providerFailed(let message):
            "Result explanation failed: \(message)"
        case .invalidOutput(let message):
            "Result explanation returned data ASTRA could not read: \(message)"
        }
    }
}

struct AgentQueryResultExplanationGenerator: QueryResultExplanationGenerating {
    var workspacePath: String
    var utilityRuntime: AgentUtilityRuntimeConfiguration

    func explainResult(_ request: QueryResultExplanationRequest) async throws -> QueryResultExplanation {
        let prompt = QueryResultExplanationPromptBuilder.prompt(for: request)
        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: utilityRuntime,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw QueryResultExplanationError.providerFailed(message.isEmpty ? "Exit code \(result.exitCode)" : String(message.prefix(400)))
        }

        guard let explanation = QueryResultExplanationParser.parse(from: result.output) else {
            throw QueryResultExplanationError.invalidOutput(String(result.output.prefix(400)))
        }

        return explanation.normalized()
    }
}

enum QueryResultExplanationPromptBuilder {
    static func prompt(for request: QueryResultExplanationRequest) -> String {
        let context = request.taskContext.map { task in
            """
            Task title: \(task.taskTitle)
            Task goal: \(task.taskGoal)
            Workspace: \(task.workspaceName)
            """
        } ?? "Task context: none"

        return """
        You are ASTRA's AI result explanation assistant for a SQL data shelf.
        Explain the returned query preview in plain analytical language.
        Do not run commands. Do not request more data. Do not infer facts that are not supported by the SQL, task context, or returned rows.

        Return exactly one structured line using this prefix and no markdown:
        ASTRA_RESULT_EXPLANATION {"version":1,"headline":"one sentence result takeaway","summary":"short paragraph","keyFindings":["finding"],"anomalies":["unexpected pattern"],"caveats":["limitation"],"followUps":["next analysis question"],"checks":[{"status":"passed|warning|blocked|info","label":"reason"}]}

        Rules:
        - Treat the returned rows as a preview, especially when the row limit may truncate the result.
        - Mention row count, grain, and aggregation limits when they matter.
        - If the result has zero rows, explain likely interpretations without pretending to know the true cause.
        - Prefer concrete comparisons from the returned values over generic commentary.
        - Put uncertainty and data-quality issues in caveats or checks.
        - Use checks with concrete reasons, not a fake confidence number.

        Context:
        \(context)

        Query metadata:
        Title: \(request.title)
        Connection: \(request.connection.displayName)
        Dialect: \(request.dialect.displayName)
        Row limit: \(request.rowLimit)
        Dry run: \(dryRunSummary(request.dryRunResult))

        AI Brief, if available:
        \(briefSummary(request.brief))

        Loaded schema context:
        \(schemaSummary(request.schemaCatalog))

        SQL:
        \(request.sql)

        Query result preview:
        \(resultSummary(request.executionResult, rowLimit: request.rowLimit))
        """
    }

    private static func dryRunSummary(_ dryRun: QueryDryRunResult?) -> String {
        guard let dryRun else { return "not available" }
        if let bytes = dryRun.bytesProcessed {
            return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); \(dryRun.message)"
        }
        return dryRun.message
    }

    private static func briefSummary(_ brief: QueryBrief?) -> String {
        guard let brief else { return "not available" }
        var lines = [
            "Goal: \(brief.goal)",
            "Grain: \(brief.grain)",
            "Assumptions: \(brief.assumptions.joined(separator: "; "))"
        ]
        if !brief.checks.isEmpty {
            lines.append("Checks: \(brief.checks.map { "\($0.status.rawValue): \($0.label)" }.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func schemaSummary(_ catalog: SchemaCatalog?) -> String {
        guard let catalog, !catalog.datasets.isEmpty else {
            return "No schema loaded in the shelf."
        }

        var lines: [String] = []
        for dataset in catalog.datasets.prefix(4) {
            lines.append("Dataset \(dataset.displayName):")
            for table in dataset.tables.prefix(8) {
                let columns = table.columns.prefix(8).map { "\($0.name):\($0.type)" }.joined(separator: ", ")
                if columns.isEmpty {
                    lines.append("- \(table.fullName) (\(table.type))")
                } else {
                    lines.append("- \(table.fullName) (\(table.type)): \(columns)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func resultSummary(_ result: QueryExecutionResult, rowLimit: Int) -> String {
        var lines = [
            "Message: \(result.message)",
            "Rows returned: \(result.rowCount)",
            "Preview row limit: \(rowLimit)",
            "Columns: \(result.columns.map { "\($0.name):\($0.type)" }.joined(separator: ", "))"
        ]
        if let bytes = result.bytesProcessed {
            lines.append("Bytes processed: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        }
        if let elapsed = result.elapsedMilliseconds {
            lines.append("Elapsed: \(elapsed) ms")
        }

        let headers = result.columns.map(\.name)
        if headers.isEmpty {
            lines.append("Rows: none")
            return lines.joined(separator: "\n")
        }

        lines.append("Rows:")
        for row in result.rows.prefix(25) {
            let pairs = headers.enumerated().map { index, header in
                let value = row.indices.contains(index) ? row[index] : ""
                return "\(header)=\(truncatedCell(value))"
            }
            lines.append("- \(pairs.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func truncatedCell(_ value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 160 else { return trimmed }
        return "\(trimmed.prefix(157))..."
    }
}

enum QueryResultExplanationParser {
    static func parse(from output: String) -> QueryResultExplanation? {
        if let prefixed = prefixedPayload(in: output),
           let explanation = decode(prefixed) {
            return explanation
        }

        if let json = firstJSONObject(in: output),
           let explanation = decode(json) {
            return explanation
        }

        return nil
    }

    private static func prefixedPayload(in output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("ASTRA_RESULT_EXPLANATION") else { continue }
            return trimmed.replacingOccurrences(of: "ASTRA_RESULT_EXPLANATION", with: "")
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

    private static func decode(_ payload: String) -> QueryResultExplanation? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QueryResultExplanation.self, from: data)
    }
}
