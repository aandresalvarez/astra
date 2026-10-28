import Foundation
import ASTRAModels
import ASTRACore

/// A read-only projection of the protected owner's run-scoped audit events.
/// It never grants admission or replaces the execution journal.
enum RuntimeLaunchPresentation {
    struct Receipt: Decodable {
        struct ProcessStart: Decodable {
            let startedSeconds: TimeInterval
            var startedMicroseconds: Int?
            var date: Date { Date(timeIntervalSince1970: startedSeconds + Double(startedMicroseconds ?? 0) / 1e6) }
        }
        let state: String
        var preparationStage: String?
        var preparationResource: String?
        var providerProcess: ProcessStart?
    }

    struct Preparation {
        let state: TaskRuntimeHealthState
        let message: String
        let detail: String
    }

    static func receipt(for run: TaskRunSnapshot, events: [TaskEventSnapshot]) -> Receipt? {
        let latest = events.filter { $0.runID == run.id && $0.type == TaskEventTypes.System.runtimeExecutionOwnership.rawValue }
            .max { $0.timestamp < $1.timestamp }
        return latest.flatMap { try? JSONDecoder().decode(Receipt.self, from: Data($0.payload.utf8)) }
    }

    static func preparation(for run: TaskRunSnapshot, events: [TaskEventSnapshot]) -> Preparation? {
        guard run.status == .running, let receipt = receipt(for: run, events: events),
              receipt.providerProcess == nil else { return nil }
        if receipt.state == "preparing", receipt.preparationStage == "waiting_for_provider" {
            let provider = receipt.preparationResource?.split(separator: ":", maxSplits: 1).first
                .flatMap { AgentRuntimeID(rawValue: String($0)) }?.displayName ?? "The provider"
            return .init(state: .waitingForResource, message: "Waiting for provider configuration",
                detail: "\(provider) has not started. Its shared configuration is reserved by another execution. This wait is bounded by the preparation limit and remaining run time; Stop cancels the wait.")
        }
        guard receipt.state == "preparing" || receipt.state == "launching" else { return nil }
        return .init(state: .preparing, message: receipt.state == "launching" ? "Starting provider" : "Preparing execution",
            detail: "ASTRA is preparing this attempt. The provider has not reported a running process yet.")
    }

    static func terminalDetail(run: TaskRunSnapshot?, events: [TaskEventSnapshot]) -> TaskDecisionDockDetail? {
        guard let run, let receipt = receipt(for: run, events: events), receipt.providerProcess == nil,
              receipt.state == "preparing" || receipt.state == "notStarted" else { return nil }
        let cancelled = run.status == .cancelled
        guard cancelled || run.stopReason == RuntimeProviderStateWaitTimeout.stopReason else { return nil }
        return .init(id: "runtime-unlaunched-terminal",
            title: cancelled ? "Cancelled before provider start" : "Provider did not start",
            summary: cancelled ? "Send a new instruction to continue. Your task history and files are preserved."
                : "Waiting for provider configuration exceeded the preparation limit. Your work is preserved; send a new instruction when the resource is available.",
            systemImage: "stop.circle", tone: .attention)
    }

    static func statusLabel(run: TaskRunSnapshot, events: [TaskEventSnapshot]) -> String? {
        guard let preparation = preparation(for: run, events: events) else { return nil }
        return preparation.state == .waitingForResource ? "Waiting for resource" : "Preparing"
    }

    static func durationLabel(run: TaskRunSnapshot, events: [TaskEventSnapshot], now: Date,
                              format: (Int) -> String) -> String? {
        guard run.status == .running || run.completedAt != nil else { return nil }
        let end = run.completedAt ?? now
        let elapsed = format(max(0, Int(end.timeIntervalSince(run.startedAt))))
        let receipt = receipt(for: run, events: events)
        if let started = receipt?.providerProcess?.date {
            let execution = format(max(0, Int(end.timeIntervalSince(started))))
            let preparation = max(0, Int(started.timeIntervalSince(run.startedAt)))
            let label = run.status == .running ? "Running for \(execution)" : "Ran for \(execution)"
            return preparation > 0 ? label + " · preparation " + format(preparation) : label
        }
        if let preparation = preparation(for: run, events: events) {
            return preparation.message + " · " + elapsed
        }
        if run.status == .cancelled, receipt?.state == "preparing" || receipt?.state == "notStarted" {
            return "Elapsed \(elapsed) · cancelled before provider start"
        }
        return "Elapsed \(elapsed)"
    }
}
