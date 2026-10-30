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
        var providerLaunchCount: Int?
        var settlementInProgress: Bool?
        var settlementLocalWorkStopped: Bool?
        var settlementToolsStopped: Bool?

        var preparationHasSettled: Bool {
            state == "notStarted" && settlementInProgress == false
                && settlementLocalWorkStopped == true && settlementToolsStopped == true
        }
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
              (receipt.providerLaunchCount ?? 0) == 0,
              receipt.state == "preparing" || receipt.state == "notStarted" else { return nil }
        let cancelled = run.status == .cancelled
        let reserved = run.stopReason == RuntimeProviderResourceRegistry.Block.stopReason
        guard cancelled || reserved || run.stopReason == RuntimeProviderStateWaitTimeout.stopReason else { return nil }
        if cancelled, !receipt.preparationHasSettled {
            return .init(id: "runtime-unlaunched-stopping", title: "Stopping preparation",
                summary: "ASTRA is waiting for preparation and its tools to stop. Resources remain reserved until cleanup is confirmed.",
                systemImage: "hourglass", tone: .attention)
        }
        return .init(id: "runtime-unlaunched-terminal",
            title: cancelled ? "Cancelled before provider start" : "Provider did not start",
            summary: cancelled ? "Send a new instruction to continue. Your task history and files are preserved."
                : reserved ? "Shared configuration remains protected. Review the reservation described in the latest output before trying again. Your task history and files are preserved."
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
        // A fallback can launch twice within one run. The latest process start
        // cannot split that run into preparation and execution intervals.
        if hasMultipleLaunches(run: run, receipt: receipt, events: events) { return "Elapsed \(elapsed)" }
        if let started = receipt?.providerProcess?.date {
            let execution = format(max(0, Int(end.timeIntervalSince(started))))
            let preparation = max(0, Int(started.timeIntervalSince(run.startedAt)))
            let label = run.status == .running ? "Running for \(execution)" : "Ran for \(execution)"
            return preparation > 0 ? label + " · preparation " + format(preparation) : label
        }
        if let preparation = preparation(for: run, events: events) {
            return preparation.message + " · " + elapsed
        }
        if run.status == .cancelled, (receipt?.providerLaunchCount ?? 0) == 0,
           receipt?.state == "preparing" || receipt?.state == "notStarted" {
            return "Elapsed \(elapsed) · " + (receipt?.preparationHasSettled == true
                ? "cancelled before provider start" : "stopping preparation")
        }
        return "Elapsed \(elapsed)"
    }

    private static func hasMultipleLaunches(run: TaskRunSnapshot, receipt: Receipt?, events: [TaskEventSnapshot]) -> Bool {
        if let count = receipt?.providerLaunchCount { return count > 1 }
        // Older journals have no count; use the distinct starts still present
        // in their history. New journals carry the count in their latest anchor.
        var starts = Set<Date>()
        for event in events where event.runID == run.id && event.type == TaskEventTypes.System.runtimeExecutionOwnership.rawValue {
            if let value = try? JSONDecoder().decode(Receipt.self, from: Data(event.payload.utf8)),
               let started = value.providerProcess?.date {
                starts.insert(started)
                if starts.count > 1 { return true }
            }
        }
        return false
    }
}
