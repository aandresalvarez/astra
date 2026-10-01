import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The launch-time backstop for PHI approval.
///
/// The composer and the decision dock ask before a user switches runtime,
/// but a launch can still change the runtime on its own: a persisted runtime
/// that is no longer registered falls back to the default, and a capability
/// reroute picks another provider. Either could carry a conversation from a
/// runtime the user approved for PHI to one they did not. This gate runs on
/// the runtime a launch is about to use, before anything is sent, and stops
/// the run unless the user has acknowledged that move.
enum RuntimeSensitiveDataLaunchGate {
    struct Block: Equatable {
        /// Raw id, so a runtime that is no longer registered still names
        /// where the conversation was.
        let previousRuntimeID: String
        let target: AgentRuntimeID
    }

    /// Where the conversation's content last went: the latest run's runtime.
    /// A run this gate stopped keeps the runtime it was meant for, so a
    /// blocked attempt never makes the unapproved runtime look like home.
    static func conversationRuntimeID(of task: AgentTask) -> String? {
        latestRun(of: task)?.runtimeID
    }

    /// Nil when the launch may proceed. With no earlier run, the runtime the
    /// user asked for stands in for the conversation's: a first message
    /// rerouted off an approved runtime is the same risk.
    @MainActor
    static func block(
        task: AgentTask,
        requestedRuntime: AgentRuntimeID,
        launchRuntime: AgentRuntimeID,
        isApproved: (AgentRuntimeID) -> Bool = { RuntimeProviderSettingsStore.isSensitiveDataApproved(for: $0) }
    ) -> Block? {
        let latest = latestRun(of: task)
        let previousRaw = latest?.runtimeID ?? requestedRuntime.rawValue
        guard let previous = AgentRuntimeID(rawValue: previousRaw),
              RuntimeSensitiveDataSwitchPolicy.requiresAcknowledgement(
                  from: previous,
                  to: launchRuntime,
                  hasConversation: true,
                  isApproved: isApproved
              ) else { return nil }
        let since = latest?.startedAt ?? .distantPast
        let acknowledged = task.events.contains { event in
            event.type == TaskEventTypes.System.sensitiveDataRiskAcknowledged.rawValue
                && event.timestamp >= since
                && RuntimeSensitiveDataRiskAcknowledgement.decode(from: event.payload)?.runtimeID == launchRuntime.rawValue
        }
        return acknowledged ? nil : Block(previousRuntimeID: previousRaw, target: launchRuntime)
    }

    @MainActor
    static func record(
        _ block: Block,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase
    ) {
        run.runtimeID = block.previousRuntimeID
        let previous = AgentRuntimeID(rawValue: block.previousRuntimeID)?.displayName ?? block.previousRuntimeID
        let target = block.target.displayName
        let message = "This conversation last ran on \(previous), which you marked approved for PHI and sensitive data. "
            + "ASTRA was about to send it to \(target), which is not approved, so it stopped before launching."
        AgentRuntimeCapabilityBlockRecorder.apply(
            TaskRuntimeCompatibilityLaunchBlock(
                stopReason: TaskRunStopReason.runtimeSensitiveDataUnapproved.rawValue,
                title: "\(target) is not approved for sensitive data",
                message: message,
                remediation: "Switch to \(target) and acknowledge the risk, or pick an approved runtime in the composer.",
                missingCapabilities: [],
                suggestedRuntime: block.target
            ),
            runtime: block.target,
            task: task,
            run: run,
            modelContext: modelContext,
            phase: phase,
            kind: .sensitiveDataUnapproved,
            eventText: message
        )
    }

    private static func latestRun(of task: AgentTask) -> TaskRun? {
        task.runs.max(by: { $0.startedAt < $1.startedAt })
    }
}

extension AgentRuntimeLaunchRuntimeResolver.LaunchRuntimeResolution {
    /// The resolution with any reroute dropped, for a launch the sensitive
    /// data gate stopped: nothing may rewrite the task's runtime toward a
    /// provider the user has not accepted.
    var withoutReroute: Self {
        Self(
            requestedRuntime: requestedRuntime,
            runtime: requestedRuntime,
            requirements: requirements,
            incompatibilities: incompatibilities,
            launchBlock: launchBlock,
            selectedRuntimeEvidence: selectedRuntimeEvidence,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot,
            contractDigest: contractDigest
        )
    }
}
