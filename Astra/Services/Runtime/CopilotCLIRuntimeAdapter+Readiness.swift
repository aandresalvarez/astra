import Foundation

extension CopilotCLIRuntimeAdapter {
    func readinessReport(
        configuration: RuntimeReadinessConfiguration,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessReport {
        let prerequisite = descriptor.prerequisite
        let executable = probes.resolvedExecutable(
            configuredPath: configuration.executablePath(for: id),
            binary: prerequisite.binary
        )
        let cliStatus = await probes.checkExecutable(
            id: readinessCheckID,
            title: prerequisite.displayName,
            executable: executable,
            args: prerequisite.livenessArgs,
            missingDetail: "\(prerequisite.displayName) was not found.",
            installHint: prerequisite.installHint
        )

        var checks = [cliStatus.check]
        if cliStatus.isReady {
            checks.append(copilotAccountDeferredCheck())
        }
        return RuntimeReadinessReport(checks: checks)
    }

    func modelAvailabilityCheck(configuration _: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let result = await CopilotModelAvailabilityService().refreshAndPersist()
        switch result {
        case .available(let models):
            return RuntimeReadinessCheck(
                id: "copilot-models",
                title: "Copilot models",
                detail: "Available: \(models.joined(separator: ", "))",
                state: .ready,
                remediation: nil
            )
        case .unavailable(let reason):
            return RuntimeReadinessCheck(
                id: "copilot-models",
                title: "Copilot models",
                detail: "Using cached or default model choices until account model access can be verified.",
                state: .warning,
                remediation: reason
            )
        }
    }

    func installPlan(detectExecutable: @Sendable (String) -> String) -> RuntimeCLIInstallPlan? {
        if let brew = detectedExecutable(named: "brew", detectExecutable: detectExecutable) {
            return RuntimeCLIInstallPlan(
                runtime: id,
                installerName: "Homebrew",
                executablePath: brew,
                arguments: ["install", "copilot-cli"],
                displayCommand: "brew install copilot-cli"
            )
        }
        guard let npm = detectedExecutable(named: "npm", detectExecutable: detectExecutable) else {
            return nil
        }
        return RuntimeCLIInstallPlan(
            runtime: id,
            installerName: "npm",
            executablePath: npm,
            arguments: ["install", "-g", "@github/copilot"],
            displayCommand: "npm install -g @github/copilot"
        )
    }

    private func copilotAccountDeferredCheck() -> RuntimeReadinessCheck {
        let tokenKeys = ["GH_TOKEN", "GITHUB_TOKEN"]
        let hasToken = tokenKeys.contains { key in
            !(ProcessInfo.processInfo.environment[key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        return RuntimeReadinessCheck(
            id: "copilot-account",
            title: "Copilot account",
            detail: hasToken
                ? "CLI is available. GitHub token environment is present; Copilot will validate account access when a task starts."
                : "CLI is available. The Copilot CLI does not expose a safe local auth status check, so account validation happens when a task starts.",
            state: .ready,
            remediation: nil
        )
    }
}
