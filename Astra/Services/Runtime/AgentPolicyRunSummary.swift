import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// What a finished run reports about itself.
///
/// Split out of `AgentPolicyAdapters` because it reads in the opposite
/// direction from everything else there: the rest of that file decides what a
/// run may do before it starts, while this reconstructs what it did from the
/// events it left behind. The one thing the two halves must agree on is
/// exposure - the summary copies `environmentKeyNames` and
/// `brokeredCredentialLabels` from the manifest rather than re-deriving them,
/// so a run can never be summarised as holding a credential the launch
/// stripped.
extension AgentPolicyManifestService {
    @MainActor
    static func recordPostRunSummary(task: AgentTask, run: TaskRun, modelContext: ModelContext) {
        let runEvents = task.events.filter { $0.run?.id == run.id }
        let manifest = latestManifest(in: runEvents)
        let deniedActionValues = deniedActions(from: runEvents)
        let explicitDeniedEventCount = runEvents.filter {
            $0.type == "permission.denied" || $0.type == "permission.approval.requested"
        }.count
        let summary = PolicyRunSummary(
            runID: run.id,
            status: run.status.rawValue,
            stopReason: run.stopReason,
            toolUseCount: runEvents.filter { $0.type == "tool.use" }.count,
            deniedCount: max(explicitDeniedEventCount, deniedActionValues.count),
            fileChangeCount: run.fileChanges.count,
            toolsUsed: toolsUsed(from: runEvents),
            commandsRun: commandsRun(from: runEvents),
            deniedActions: deniedActionValues,
            filesChanged: run.fileChanges.map(\.path).sorted(),
            externalDomains: externalDomains(from: runEvents),
            environmentKeyNames: manifest?.environmentKeyNames ?? [],
            brokeredCredentialLabels: manifest?.brokeredCredentialLabels ?? [],
            approvalsGranted: manifest?.approvalsGranted ?? [],
            approvalGrantDescriptions: manifest?.approvalGrants.map(\.displayName) ?? [],
            usedBroadProviderPermissions: manifest?.providerRender.usesBroadProviderPermissions ?? false,
            exceededInitialPermissionLevel: manifest?.policyScope == .oneRunEscalation || manifest?.providerRender.usesBroadProviderPermissions == true,
            completedAt: run.completedAt ?? Date()
        )
        let payload = (try? summary.encodedString()) ?? "{}"
        modelContext.insert(TaskEvent(task: task, type: summaryEventType, payload: payload, run: run))
    }

    private struct PolicyRunSummary: Codable {
        var runID: UUID
        var status: String
        var stopReason: String
        var toolUseCount: Int
        var deniedCount: Int
        var fileChangeCount: Int
        var toolsUsed: [String]
        var commandsRun: [String]
        var deniedActions: [String]
        var filesChanged: [String]
        var externalDomains: [String]
        var environmentKeyNames: [String]
        var brokeredCredentialLabels: [String]
        var approvalsGranted: [String]
        var approvalGrantDescriptions: [String]
        var usedBroadProviderPermissions: Bool
        var exceededInitialPermissionLevel: Bool
        var completedAt: Date

        func encodedString() throws -> String {
            let data = try JSONEncoder().encode(self)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    private static func latestManifest(in events: [TaskEvent]) -> RunPermissionManifest? {
        events
            .filter { $0.type == preflightEventType }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { event -> RunPermissionManifest? in
                guard let data = event.payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(RunPermissionManifest.self, from: data)
            }
            .last
    }

    private static func toolsUsed(from events: [TaskEvent]) -> [String] {
        uniqueLimited(events.compactMap { event in
            guard event.type == "tool.use" else { return nil }
            return toolName(fromToolUsePayload: event.payload)
        })
    }

    private static func commandsRun(from events: [TaskEvent]) -> [String] {
        uniqueLimited(events.compactMap { event in
            guard event.type == "tool.use",
                  let tool = toolName(fromToolUsePayload: event.payload)?.lowercased(),
                  tool == "bash" || tool == "shell",
                  let summary = toolSummary(fromToolUsePayload: event.payload) else {
                return nil
            }
            return LogSanitizer.sanitize(summary, maxLength: 240)
        })
    }

    private static func deniedActions(from events: [TaskEvent]) -> [String] {
        let explicitActions: [String] = events.compactMap { event -> String? in
            guard event.type == "permission.denied" || event.type == "permission.approval.requested" else { return nil }
            return LogSanitizer.sanitize(event.payload, maxLength: 240)
        }
        let providerSandboxActions: [String] = events.compactMap(providerSandboxDeniedAction(from:))
        let osSandboxActions: [String] = events.compactMap(osSandboxDeniedAction(from:))
        return uniqueLimited(explicitActions + providerSandboxActions + osSandboxActions)
    }

    private static func providerSandboxDeniedAction(from event: TaskEvent) -> String? {
        guard event.type == "agent.response" || event.type == "agent.thinking" else { return nil }
        let lower = event.payload.lowercased()
        guard lower.contains("write") || lower.contains("create") else { return nil }
        guard lower.contains("blocked") || lower.contains("rejected") || lower.contains("denied") else { return nil }
        guard lower.contains("sandbox") || lower.contains("outside") || lower.contains("workspace") else { return nil }
        guard let path = filesystemPaths(in: event.payload).first else { return nil }
        return "provider_sandbox_blocked_write path=\(path)"
    }

    private static func osSandboxDeniedAction(from event: TaskEvent) -> String? {
        guard event.type == "tool.result" || event.type == "agent.response" || event.type == "agent.thinking" else {
            return nil
        }
        return RuntimeSandboxDenialDiagnostics.fileDenial(in: event.payload)?.deniedActionValue
    }

    private static func filesystemPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:~|/)[^\s`"'<>]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            let value = String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);:"))
            return value.isEmpty ? nil : value
        }
    }

    private static func externalDomains(from events: [TaskEvent]) -> [String] {
        let observedURLs = events.flatMap { urls(in: $0.payload) }
        return uniqueLimited(observedURLs.compactMap { URL(string: $0)?.host?.lowercased() }, limit: 20)
    }

    private static func toolName(fromToolUsePayload payload: String) -> String? {
        guard payload.hasPrefix("Using tool:") else { return nil }
        let remainder = payload.dropFirst("Using tool:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = remainder.split(separator: ":", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private static func toolSummary(fromToolUsePayload payload: String) -> String? {
        guard let range = payload.range(of: ": ") else { return nil }
        let afterToolPrefix = payload[range.upperBound...]
        guard let secondColon = afterToolPrefix.firstIndex(of: ":") else { return nil }
        let summaryStart = afterToolPrefix.index(after: secondColon)
        let summary = afterToolPrefix[summaryStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    private static func urls(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"')<>]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            return String(text[valueRange])
        }
    }

    private static func uniqueLimited(_ values: [String], limit: Int = 12) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count >= limit { break }
        }
        return result
    }
}
