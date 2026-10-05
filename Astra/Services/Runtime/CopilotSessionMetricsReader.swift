import Foundation
import ASTRAModels
import ASTRACore

struct CopilotSessionMetrics: Equatable {
    let sessionID: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double?
    let durationMs: Int?
    let turns: Int?

    var totalTokens: Int { inputTokens + outputTokens }

    var event: AgentEvent {
        .stats(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            durationMs: durationMs,
            turns: turns
        )
    }
}

/// A Copilot `session-state/<id>` session that mentions the task.
struct CopilotSessionCandidate: Equatable {
    let sessionID: String
    let modifiedAt: Date
    /// The session's final recorded usage, when it has one.
    let metrics: CopilotSessionMetrics?
}

enum CopilotSessionMetricsReader {
    /// How long before a run started its own session may last have been written and still be read for usage.
    static let metricsWindow: TimeInterval = 60

    /// A launch whose stream never named its session still left it in Copilot's state directory; keep that
    /// id so the next follow-up can resume it. A run that already knows its session (a resumed one) is left
    /// alone; a run that does not is a fresh launch, so what it created replaces whatever older session the
    /// task still names, as a streamed start event would.
    @MainActor
    static func adoptSession(_ sessionID: String, task: AgentTask, run: TaskRun) {
        let discovered = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !discovered.isEmpty,
              run.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
        run.providerSessionId = discovered
        task.sessionId = discovered
    }

    /// Accepts only a session a fresh launch created: written during this run (whole-second file-system
    /// timestamps allowed for), and neither the session the task still names nor one another run recorded.
    /// An older conversation that merely falls inside the pre-run metrics window is one the fresh launch
    /// deliberately did not continue, so it is never adopted as this run's output.
    @MainActor
    static func launchCreatedSessionFilter(task: AgentTask, run: TaskRun, runStartedAt: Date) -> (String, Date) -> Bool {
        let startedAt = Date(timeIntervalSince1970: runStartedAt.timeIntervalSince1970.rounded(.down))
        let claimed = Set(([task.sessionId] + task.runs.filter { $0.id != run.id }.map(\.providerSessionId))
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
        return { sessionID, modifiedAt in modifiedAt >= startedAt && !claimed.contains(sessionID) }
    }

    /// The newest session under `copilotHome` written at or after `modifiedSince` that `accepts` (checked
    /// before its events are read) and whose events mention the task.
    static func newestTaskSession(
        copilotHome: String,
        taskID: UUID,
        modifiedSince: Date,
        fileManager: FileManager = .default,
        accepts: (_ sessionID: String, _ modifiedAt: Date) -> Bool
    ) -> CopilotSessionCandidate? {
        guard !copilotHome.isEmpty else { return nil }
        let copilotHomeURL = URL(fileURLWithPath: copilotHome, isDirectory: true)
        let hostFileAccess = HostFileAccessBroker(fileManager: fileManager)
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: copilotHomeURL)
        let sessionStateURL = copilotHomeURL
            .appendingPathComponent("session-state", isDirectory: true)
        guard let children = try? hostFileAccess.contentsOfDirectory(
            at: sessionStateURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
            intent: accessIntent
        ) else {
            return nil
        }

        let lowerTaskID = taskID.uuidString.lowercased()
        let shortTaskID = String(lowerTaskID.prefix(8))
        let candidates = children.compactMap { sessionURL -> (url: URL, sessionID: String, modified: Date)? in
            let eventsURL = sessionURL.appendingPathComponent("events.jsonl")
            guard hostFileAccess.fileExists(at: eventsURL, intent: accessIntent) else { return nil }
            let modified = (try? eventsURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return (eventsURL, sessionURL.lastPathComponent, modified)
        }
        .filter { $0.modified >= modifiedSince && accepts($0.sessionID, $0.modified) }
        .sorted { $0.modified > $1.modified }

        for candidate in candidates {
            guard let content = try? hostFileAccess.readString(
                at: candidate.url,
                encoding: .utf8,
                intent: accessIntent
            ) else {
                continue
            }
            let lowerContent = content.lowercased()
            guard lowerContent.contains(lowerTaskID) || lowerContent.contains(shortTaskID) else {
                continue
            }
            let metrics = finalStatsEvent(in: content).map { stats in
                CopilotSessionMetrics(
                    sessionID: candidate.sessionID,
                    inputTokens: stats.input,
                    outputTokens: stats.output,
                    costUSD: stats.cost,
                    durationMs: stats.duration,
                    turns: stats.turns
                )
            }
            return CopilotSessionCandidate(sessionID: candidate.sessionID, modifiedAt: candidate.modified, metrics: metrics)
        }

        return nil
    }

    private static func finalStatsEvent(in content: String) -> (input: Int, output: Int, cost: Double?, duration: Int?, turns: Int?)? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).reversed()
        for line in lines {
            guard line.contains(#""session.shutdown""#) || line.contains(#""modelMetrics""#) else {
                continue
            }
            let events = CopilotStreamEventParser.parseAgentEvents(line: String(line))
            for event in events {
                if case .stats(let input, let output, let cost, let duration, let turns) = event,
                   input > 0 || output > 0 {
                    return (input, output, cost, duration, turns)
                }
            }
        }
        return nil
    }
}
