import Foundation
import SwiftData

/// Scans Claude Code's session history (~/.claude/projects/) to discover
/// previous threads for a workspace path and import them as tasks.
enum SessionScanner {

    /// Marker payload written on the start event of every imported session, used
    /// to recognise (and de-duplicate) imports later. Kept as a shared constant
    /// so `TaskStoreMaintenance` and the import code agree on the exact string.
    static let importedSessionMarker = "Imported from Claude Code session"

    struct DiscoveredSession {
        let sessionId: String
        let goal: String
        let userMessages: [String]
        let totalTokens: Int
        let startedAt: Date
        let lastActivity: Date
        let model: String?
    }

    /// Scan ~/.claude/projects/ for sessions that match this workspace path.
    static func discoverSessions(workspacePath: String) -> [DiscoveredSession] {
        let claudeDir = NSHomeDirectory() + "/.claude/projects"
        guard FileManager.default.fileExists(atPath: claudeDir) else { return [] }

        // Claude Code encodes paths by replacing / with -
        let encodedPath = workspacePath
            .replacingOccurrences(of: "/", with: "-")
        let projectDir = claudeDir + "/" + encodedPath

        guard FileManager.default.fileExists(atPath: projectDir) else { return [] }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { return [] }

        var sessions: [DiscoveredSession] = []

        for file in files where file.hasSuffix(".jsonl") {
            let sessionId = String(file.dropLast(6)) // remove .jsonl
            let fullPath = projectDir + "/" + file

            if let session = parseSession(at: fullPath, sessionId: sessionId) {
                // Filter out tiny sessions (< 500 tokens) — likely system/spec engine calls
                if session.totalTokens >= 500 {
                    sessions.append(session)
                }
            }
        }

        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Filter discovered sessions down to those worth importing: ones not
    /// already imported (idempotency, keyed by `sessionId`) and ones that carry
    /// real task intent (drop bare greeting/identity-probe sessions). Pure so it
    /// can be unit-tested without a model context.
    static func sessionsToImport(
        _ sessions: [DiscoveredSession],
        existingSessionIds: Set<String>
    ) -> [DiscoveredSession] {
        sessions.filter { session in
            guard !existingSessionIds.contains(session.sessionId) else { return false }
            return !TaskConversationSignal.isLowSignalConversation(
                goal: session.goal,
                userMessages: session.userMessages
            )
        }
    }

    /// Import discovered sessions as completed tasks into a workspace.
    ///
    /// Idempotent: sessions already present (matched by `sessionId`) are skipped,
    /// so re-running an import can never create duplicate cards. Trivial
    /// greeting/probe sessions are filtered out entirely.
    @discardableResult
    static func importSessions(
        _ sessions: [DiscoveredSession],
        into workspace: Workspace,
        modelContext: ModelContext
    ) -> Int {
        let existingSessionIds = Set(workspace.tasks.compactMap { task -> String? in
            guard let id = task.sessionId, !id.isEmpty else { return nil }
            return id
        })
        let pending = sessionsToImport(sessions, existingSessionIds: existingSessionIds)

        var count = 0
        for session in pending {
            let title = extractTitle(from: session.goal)
            let task = AgentTask(
                title: title,
                goal: session.goal,
                workspace: workspace,
                tokenBudget: session.totalTokens,
                model: session.model ?? TaskExecutionDefaults.model,
                runtime: .claudeCode
            )
            task.status = .completed
            task.isDone = true
            task.tokensUsed = session.totalTokens
            task.sessionId = session.sessionId
            task.createdAt = session.startedAt
            task.updatedAt = session.lastActivity
            task.completedAt = session.lastActivity
            modelContext.insert(task)

            // Create a single run record
            let run = TaskRun(task: task)
            run.status = .completed
            run.startedAt = session.startedAt
            run.completedAt = session.lastActivity
            run.tokensUsed = session.totalTokens
            run.exitCode = 0
            run.output = session.userMessages.joined(separator: "\n---\n")
            run.typedStopReason = .completed
            modelContext.insert(run)

            // Create conversation events from user messages
            let startEvent = TaskEvent(
                task: task,
                eventType: TaskEventTypes.Task.started,
                payload: importedSessionMarker,
                run: run
            )
            startEvent.timestamp = session.startedAt
            modelContext.insert(startEvent)

            for (i, msg) in session.userMessages.enumerated() {
                let event = TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Conversation.userMessage,
                    payload: String(msg.prefix(2000)),
                    run: run
                )
                // Spread timestamps evenly
                let fraction = Double(i + 1) / Double(session.userMessages.count + 1)
                event.timestamp = session.startedAt.addingTimeInterval(
                    session.lastActivity.timeIntervalSince(session.startedAt) * fraction
                )
                modelContext.insert(event)
            }

            let endEvent = TaskEvent(
                task: task,
                eventType: TaskEventTypes.Task.completed,
                payload: "Session completed",
                run: run
            )
            endEvent.timestamp = session.lastActivity
            modelContext.insert(endEvent)

            count += 1
        }
        return count
    }

    // MARK: - Private

    private static func parseSession(at path: String, sessionId: String) -> DiscoveredSession? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var totalInput = 0
        var totalOutput = 0
        var userMessages: [String] = []
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var model: String?
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Parse timestamp
            if let ts = obj["timestamp"] as? String {
                let date = isoFormatter.date(from: ts) ?? isoFormatterNoFrac.date(from: ts)
                if let date {
                    if firstTimestamp == nil { firstTimestamp = date }
                    lastTimestamp = date
                }
            }

            // Parse usage
            if let msg = obj["message"] as? [String: Any],
               let usage = msg["usage"] as? [String: Any] {
                totalInput += usage["input_tokens"] as? Int ?? 0
                totalOutput += usage["output_tokens"] as? Int ?? 0

                if model == nil, let m = msg["model"] as? String {
                    model = m
                }
            }

            // Collect user messages (skip system prompts)
            if obj["type"] as? String == "user",
               let msg = obj["message"] as? [String: Any],
               msg["role"] as? String == "user",
               let msgContent = msg["content"] as? String {
                // Skip system prompts injected by ASTRA
                if !msgContent.hasPrefix("You are helping the user define a task") &&
                   !msgContent.hasPrefix("Given the following conversation, extract") &&
                   !msgContent.hasPrefix("Workspace Context:") {
                    userMessages.append(msgContent)
                } else if msgContent.hasPrefix("Workspace Context:") {
                    // Extract the actual goal after the workspace context header
                    let lines = msgContent.components(separatedBy: "\n")
                    let goalLines = lines.dropFirst(2) // skip context lines
                    let goal = goalLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !goal.isEmpty { userMessages.append(goal) }
                }
            }
        }

        guard let start = firstTimestamp, let end = lastTimestamp else { return nil }
        let totalTokens = totalInput + totalOutput
        let goal = userMessages.first ?? "Claude Code session"

        return DiscoveredSession(
            sessionId: sessionId,
            goal: goal,
            userMessages: userMessages,
            totalTokens: totalTokens,
            startedAt: start,
            lastActivity: end,
            model: model
        )
    }

    private static func extractTitle(from goal: String) -> String {
        // Take first line or first sentence, capped at 60 chars
        let firstLine = goal.components(separatedBy: "\n").first ?? goal
        let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 60 { return cleaned }

        // Try to break at a word boundary
        let prefix = String(cleaned.prefix(57))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace]) + "..."
        }
        return prefix + "..."
    }
}
