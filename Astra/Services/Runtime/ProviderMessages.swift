import Foundation
import ASTRACore

enum ProviderMessages {
    static func missingExecutable(
        providerName: String,
        installAction: String,
        authAction: String
    ) -> String {
        "\(providerName) CLI not found. \(installAction), then \(authAction)"
    }

    static func missingExecutableAtPath(providerName: String, executablePath: String) -> String {
        "\(providerName) CLI not found at '\(executablePath)'. Check Settings."
    }

    static func start(providerName: String?, goal: String) -> String {
        "\(providerName ?? "Agent") started working on: \(goal)"
    }

    static func manualCompletion(providerName: String?, phase: RunPhase) -> String {
        if let providerName {
            return "\(providerName) finished."
        }
        return phase == .resume ? "Follow-up completed." : "Agent finished."
    }

    static func failurePrefix(providerName: String?, phase: RunPhase, exitCode: Int) -> String {
        if let providerName {
            return "\(providerName) exited with code \(exitCode)."
        }
        return phase == .resume ? "Follow-up failed (exit \(exitCode))." : "Agent exited with code \(exitCode)."
    }

    static func timeout(phase: RunPhase, timeoutSeconds: TimeInterval) -> String {
        let label = phase == .resume ? "Resume" : "Task"
        return "\(label) idle timeout - no output for \(Int(timeoutSeconds))s. Process killed."
    }

    static func maxTurns(phase: RunPhase, maxTurns: Int) -> String {
        if phase == .resume {
            return "Max turns reached (\(maxTurns)) during resume. Process killed."
        }
        return "Max turns reached (\(maxTurns)). Process killed."
    }
}
