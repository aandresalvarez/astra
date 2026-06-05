import Foundation

struct QueryRepairRequest: Equatable, Sendable {
    var title: String
    var originalSQL: String
    var failedSQL: String
    var dryRunError: String
    var attempt: Int
    var connection: DatabaseConnection
    var dialect: SQLDialect
    var schemaCatalog: SchemaCatalog?
    var taskContext: QueryBriefTaskContext?
}

struct QueryRepairSuggestion: Codable, Equatable, Sendable {
    var sql: String
    var summary: String
    var assumptions: [String]

    func normalized() -> QueryRepairSuggestion {
        QueryRepairSuggestion(
            sql: sql.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: Self.limited(summary, fallback: "Repaired SQL based on the dry-run error."),
            assumptions: assumptions
                .map { Self.limited($0) }
                .filter { !$0.isEmpty }
        )
    }

    private static func limited(_ value: String, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        guard resolved.count > 240 else { return resolved }
        return "\(resolved.prefix(237))..."
    }
}

protocol QueryRepairGenerating {
    func repair(_ request: QueryRepairRequest) async throws -> QueryRepairSuggestion
}

enum QueryRepairGenerationError: LocalizedError, Equatable {
    case providerFailed(String)
    case invalidOutput(String)
    case unsafeSQL(String)

    var errorDescription: String? {
        switch self {
        case .providerFailed(let message):
            "Query repair failed: \(message)"
        case .invalidOutput(let message):
            "Query repair returned data ASTRA could not read: \(message)"
        case .unsafeSQL(let message):
            message
        }
    }
}

struct AgentQueryRepairGenerator: QueryRepairGenerating {
    var workspacePath: String
    var utilityRuntime: AgentUtilityRuntimeConfiguration

    func repair(_ request: QueryRepairRequest) async throws -> QueryRepairSuggestion {
        let prompt = QueryRepairPromptBuilder.prompt(for: request)
        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: workspacePath,
            configuration: utilityRuntime,
            toolMode: .readOnly
        )

        guard result.exitCode == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw QueryRepairGenerationError.providerFailed(message.isEmpty ? "Exit code \(result.exitCode)" : String(message.prefix(400)))
        }

        guard let repair = QueryRepairParser.parse(from: result.output) else {
            throw QueryRepairGenerationError.invalidOutput(String(result.output.prefix(400)))
        }

        let normalized = repair.normalized()
        guard !normalized.sql.isEmpty else {
            throw QueryRepairGenerationError.invalidOutput("The repaired SQL was empty.")
        }
        return normalized
    }
}

enum QueryRepairPromptBuilder {
    static func prompt(for request: QueryRepairRequest) -> String {
        let context = request.taskContext.map { task in
            """
            Task title: \(task.taskTitle)
            Task goal: \(task.taskGoal)
            Workspace: \(task.workspaceName)
            """
        } ?? "Task context: none"

        return """
        You are ASTRA's SQL dry-run repair assistant.
        Repair a read-only SQL query after a database dry-run error.
        Do not run commands. Do not output DML, DDL, scripts, or multiple statements.
        Preserve the user's analytical intent and SQL dialect.

        Return exactly one structured line using this prefix and no markdown:
        ASTRA_QUERY_REPAIR {"sql":"SELECT ...","summary":"What changed","assumptions":["assumption"]}

        Rules:
        - Return only read-only SQL that starts with SELECT or WITH.
        - Keep the repair minimal and inspectable.
        - Prefer existing table and column names from the SQL or schema context.
        - Do not invent table names silently. Put any uncertainty in assumptions.
        - Do not include markdown fences.

        Context:
        \(context)

        Query metadata:
        Title: \(request.title)
        Connection: \(request.connection.displayName)
        Dialect: \(request.dialect.displayName)
        Repair attempt: \(request.attempt)

        Loaded schema context:
        \(QueryRepairPromptBuilder.schemaSummary(request.schemaCatalog))

        Original SQL:
        \(request.originalSQL)

        Failed SQL:
        \(request.failedSQL)

        Dry-run error:
        \(request.dryRunError)
        """
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

enum QueryRepairParser {
    static func parse(from output: String) -> QueryRepairSuggestion? {
        if let prefixed = prefixedPayload(in: output),
           let repair = decode(prefixed) {
            return repair
        }

        if let json = firstJSONObject(in: output),
           let repair = decode(json) {
            return repair
        }

        return nil
    }

    private static func prefixedPayload(in output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("ASTRA_QUERY_REPAIR") else { continue }
            return trimmed.replacingOccurrences(of: "ASTRA_QUERY_REPAIR", with: "")
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

    private static func decode(_ payload: String) -> QueryRepairSuggestion? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QueryRepairSuggestion.self, from: data)
    }
}
