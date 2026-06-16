import Foundation
@testable import ASTRA
import ASTRACore

enum LiveProviderDiagnostics {
    @MainActor
    static func printSummary(
        label: String,
        task: AgentTask,
        workspacePath: String,
        receivedEvents: [ParsedEvent] = []
    ) {
        print(summary(
            label: label,
            task: task,
            workspacePath: workspacePath,
            receivedEvents: receivedEvents
        ))
    }

    @MainActor
    static func summary(
        label: String,
        task: AgentTask,
        workspacePath: String,
        receivedEvents: [ParsedEvent] = []
    ) -> String {
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let run = runs.last
        let runID = run?.id
        let scopedEvents = task.events
            .filter { event in
                guard let runID else { return true }
                return event.run?.id == runID
            }
        let errorEvents = scopedEvents
            .filter { $0.type == "error" }
            .map { redacted(String($0.payload.prefix(1_000))) }
        let verificationEvents = scopedEvents
            .filter { $0.type.hasPrefix("deliverable.verification.") }
            .map { "\($0.type): \(redacted(String($0.payload.prefix(1_000))))" }
        let launchEvents = scopedEvents
            .filter { $0.type == "astra.provider_launch_signature" }
            .map { redacted(String($0.payload.prefix(1_000))) }
        let eventTypes = Set(scopedEvents.map(\.type)).sorted().joined(separator: ", ")
        let artifacts = task.artifacts
            .map(\.path)
            .sorted()
            .joined(separator: ", ")
        let fileChanges = run?.fileChanges
            .map(\.path)
            .sorted()
            .joined(separator: ", ") ?? ""
        let output = redacted(String((run?.output ?? "").prefix(1_000)))

        return """

        === \(label) live E2E debug ===
        task_status=\(task.status.rawValue)
        run_status=\(run?.status.rawValue ?? "nil")
        stop_reason=\(run?.stopReason ?? "nil")
        runtime=\(run?.runtimeID ?? "nil")
        provider_version=\(run?.providerVersion ?? "nil")
        exit_code=\(run?.exitCode.map(String.init) ?? "nil")
        session=\((run?.providerSessionId).map { String($0.prefix(8)) } ?? "nil")
        workspace=\(workspacePath)
        task_folder=\(TaskWorkspaceAccess(task: task).taskFolder)
        event_types=\(eventTypes)
        received_event_count=\(receivedEvents.count)
        file_changes=\(fileChanges)
        artifacts=\(artifacts)
        output=\(output)
        launch_events=\(launchEvents.joined(separator: " | "))
        verification_events=\(verificationEvents.joined(separator: " | "))
        error_events=\(errorEvents.joined(separator: " | "))
        ================================
        """
    }

    static func redacted(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"gho_[A-Za-z0-9_]+"#,
                with: "gho_[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9_-]+"#,
                with: "sk-[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN)=(?!\[redacted\]|sk-\[redacted\]|gho_\[redacted\])\S+"#,
                with: "$1=[redacted]",
                options: .regularExpression
            )
    }
}
