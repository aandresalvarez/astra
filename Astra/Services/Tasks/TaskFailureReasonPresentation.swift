import Foundation
import ASTRAModels

enum TaskFailureReasonPresentation {
    /// Extracts the "Remediation: ..." clause from a policy/runtime-compatibility
    /// block's free-text event payload (see `shouldStartProvider` and
    /// `AgentRuntimeCapabilityBlockRecorder`). Used by the inline run-activity
    /// issue banner (`RunIssuePresentation`), which only sees one notice's raw
    /// payload; the decision dock reads the structured
    /// `TaskRunLaunchBlockPayload` sibling event instead.
    static func policyBlockRemediation(errorPayloads: [String]) -> String? {
        guard let payload = errorPayloads.last,
              let range = payload.range(of: "Remediation:") else { return nil }
        let remediation = payload[range.upperBound...]
            .prefix { $0 != "\n" }
            .trimmingCharacters(in: .whitespaces)
        return remediation.isEmpty ? nil : remediation
    }

    static func reason(errorPayloads: [String], latestExitCode: Int?) -> String {
        guard let payload = errorPayloads.last else {
            if latestExitCode == 143 {
                return "Process killed (SIGTERM) - likely timeout."
            }
            return "The agent encountered an error. Check the activity log."
        }
        return reason(payload: payload, latestExitCode: latestExitCode)
    }

    static func reason(payload: String, latestExitCode: Int?) -> String {
        let lower = payload.lowercased()
        if lower.contains("idle timeout") || lower.contains("timed out") {
            return "Agent went idle - no output for the timeout period."
        }
        if isDockerProviderExecutableMissing(payload) {
            return "Docker image is missing the provider CLI."
        }
        if isWorkspaceManagedJobStalled(payload) {
            return "Workspace job stopped producing heartbeats."
        }
        if payload.contains("CLI not found") {
            return "Provider CLI not found. Check Settings."
        }
        if payload.hasPrefix("Workspace directory not found:") {
            return "Workspace directory not found."
        }
        if payload.contains("isolation") || payload.contains("Isolation") {
            return "Workspace isolation setup failed."
        }
        if payload.contains("exit") || payload.contains("exited") {
            if let latestExitCode {
                if latestExitCode == 143 { return "Process killed (SIGTERM) - likely timeout." }
                if latestExitCode == 137 { return "Process killed (SIGKILL) - may be out of memory." }
                if latestExitCode != 0 { return "Agent exited with code \(latestExitCode)." }
            }
        }
        return String(payload.prefix(200))
    }

    private static func isDockerProviderExecutableMissing(_ payload: String) -> Bool {
        let lower = payload.lowercased()
        return lower.contains(TaskRunStopReason.dockerProviderExecutableMissing.rawValue)
            || lower.contains("missing provider executable")
            || lower.contains("inside docker image")
            || (
                lower.contains("docker:")
                    && lower.contains("exec:")
                    && lower.contains("executable file not found in $path")
            )
    }

    private static func isWorkspaceManagedJobStalled(_ payload: String) -> Bool {
        let lower = payload.lowercased()
        return lower.contains(TaskRunStopReason.providerWorkspaceJobStalled.rawValue)
            || lower.contains("managed workspace job")
                && lower.contains("heartbeat")
    }
}
