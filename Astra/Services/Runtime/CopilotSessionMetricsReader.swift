import Foundation
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

enum CopilotSessionMetricsReader {
    static func finalMetrics(
        copilotHome: String,
        taskID: UUID,
        runStartedAt: Date,
        fileManager: FileManager = .default
    ) -> CopilotSessionMetrics? {
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
        let candidates = children.compactMap { sessionURL -> (url: URL, modified: Date)? in
            let eventsURL = sessionURL.appendingPathComponent("events.jsonl")
            guard hostFileAccess.fileExists(at: eventsURL, intent: accessIntent) else { return nil }
            let modified = (try? eventsURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return (eventsURL, modified)
        }
        .filter { $0.modified >= runStartedAt.addingTimeInterval(-60) }
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
            guard let stats = finalStatsEvent(in: content) else {
                continue
            }
            return CopilotSessionMetrics(
                sessionID: candidate.url.deletingLastPathComponent().lastPathComponent,
                inputTokens: stats.input,
                outputTokens: stats.output,
                costUSD: stats.cost,
                durationMs: stats.duration,
                turns: stats.turns
            )
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
