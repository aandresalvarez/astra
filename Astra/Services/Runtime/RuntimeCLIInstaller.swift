import Foundation
import ASTRACore

struct RuntimeCLIInstallPlan: Sendable, Equatable {
    let runtime: AgentRuntimeID
    let installerName: String
    let executablePath: String
    let arguments: [String]
    let displayCommand: String
}

struct RuntimeCLIInstallResult: Sendable, Equatable {
    let runtime: AgentRuntimeID
    let plan: RuntimeCLIInstallPlan?
    let succeeded: Bool
    let summary: String
    let detail: String?
}

struct RuntimeCLIInstaller: Sendable {
    private let runner: BinaryRunner
    private let timeout: TimeInterval
    private let detectExecutable: @Sendable (String) -> String

    init(
        runner: BinaryRunner = ProcessBinaryRunner(),
        timeout: TimeInterval = 600,
        detectExecutable: @escaping @Sendable (String) -> String = {
            RuntimePathResolver.detectExecutablePath(named: $0)
        }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.detectExecutable = detectExecutable
    }

    func plan(for runtime: AgentRuntimeID) -> RuntimeCLIInstallPlan? {
        AgentRuntimeAdapterRegistry.adapterIfRegistered(for: runtime)?
            .installPlan(detectExecutable: detectExecutable)
    }

    func install(runtime: AgentRuntimeID) async -> RuntimeCLIInstallResult {
        guard let plan = plan(for: runtime) else {
            return RuntimeCLIInstallResult(
                runtime: runtime,
                plan: nil,
                succeeded: false,
                summary: "No supported installer found for \(runtime.displayName).",
                detail: fallbackInstallHint(for: runtime)
            )
        }

        let result = await runner.run(
            path: plan.executablePath,
            args: plan.arguments,
            timeout: timeout,
            environment: installEnvironment()
        )

        guard result.isSuccess else {
            return RuntimeCLIInstallResult(
                runtime: runtime,
                plan: plan,
                succeeded: false,
                summary: "\(runtime.displayName) install failed.",
                detail: installFailureDetail(result)
            )
        }

        return RuntimeCLIInstallResult(
            runtime: runtime,
            plan: plan,
            succeeded: true,
            summary: "\(runtime.displayName) install command completed.",
            detail: "ASTRA will re-check the CLI now."
        )
    }

    private func installEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.agentPathSuffix)"
        env["NO_COLOR"] = "1"
        env["CI"] = env["CI"] ?? "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = env["HOMEBREW_NO_AUTO_UPDATE"] ?? "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = env["HOMEBREW_NO_INSTALL_CLEANUP"] ?? "1"
        return env
    }

    private func fallbackInstallHint(for runtime: AgentRuntimeID) -> String {
        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)
        return descriptor.installHint.isEmpty
            ? "Install \(runtime.displayName), then configure its executable path in Settings."
            : descriptor.installHint
    }

    private func installFailureDetail(_ result: RunResult) -> String {
        switch result.outcome {
        case .timedOut:
            return "Install timed out after \(Int(timeout))s."
        case .cancelled:
            return "Install was cancelled."
        case .launchFailed(let reason):
            return "Could not launch installer: \(reason)"
        case .exited(let code):
            let evidence = result.stderr.isEmpty ? result.stdout : result.stderr
            let compact = evidence
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if compact.isEmpty {
                return "Installer exited with status \(code)."
            }
            return "Installer exited with status \(code): \(String(compact.prefix(220)))"
        }
    }
}
