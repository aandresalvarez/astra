import Foundation
@testable import ASTRA
import ASTRACore

enum E2ETestSupport {
    struct RuntimeCase: Sendable, CustomStringConvertible {
        let runtimeID: AgentRuntimeID
        let model: String
        let directoryNameComponent: String
        let expectsSessionID: Bool
        let expectsUsageStats: Bool
        let expectsCostUSD: Bool
        let expectsTeamEvents: Bool

        var description: String {
            runtimeID.displayName
        }
    }

    static var runtimeCases: [RuntimeCase] {
        [
            RuntimeCase(
                runtimeID: .claudeCode,
                model: ProcessInfo.processInfo.environment["REAL_CLAUDE_MODEL"] ?? AgentRuntimeID.claudeCode.defaultModel,
                directoryNameComponent: "claude",
                expectsSessionID: true,
                expectsUsageStats: true,
                expectsCostUSD: true,
                expectsTeamEvents: true
            ),
            RuntimeCase(
                runtimeID: .copilotCLI,
                model: ProcessInfo.processInfo.environment["REAL_COPILOT_MODEL"] ?? AgentRuntimeID.copilotCLI.defaultModel,
                directoryNameComponent: "copilot",
                expectsSessionID: false,
                expectsUsageStats: false,
                expectsCostUSD: false,
                expectsTeamEvents: false
            )
        ]
    }

    @MainActor
    static func configureUnattended(
        _ worker: AgentRuntimeWorker,
        for runtimeCase: RuntimeCase? = nil,
        temporaryRootPath: String? = nil
    ) throws {
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue

        if let runtimeCase {
            worker.defaultRuntimeID = runtimeCase.runtimeID
            try configureExecutable(for: runtimeCase.runtimeID, worker: worker, temporaryRootPath: temporaryRootPath)
        }

        if let timeout = TimeInterval(ProcessInfo.processInfo.environment["RUN_E2E_TIMEOUT_SECONDS"] ?? "") {
            worker.timeoutSeconds = timeout
        }
    }

    @MainActor
    private static func configureExecutable(
        for runtimeID: AgentRuntimeID,
        worker: AgentRuntimeWorker,
        temporaryRootPath: String?
    ) throws {
        switch runtimeID {
        case .claudeCode:
            let path = RuntimePathResolver.detectClaudePath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("claude")
            }
            worker.claudePath = path
        case .copilotCLI:
            let path = RuntimePathResolver.detectCopilotPath()
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw E2ETestSupportError.missingExecutable("copilot")
            }
            worker.copilotPath = path
            if let temporaryRootPath {
                worker.copilotHome = copilotHomePath(forTemporaryRootPath: temporaryRootPath)
            }
        }
    }

    static func copilotHomePath(forTemporaryRootPath path: String) -> String {
        "\(path)-copilot-home"
    }

    static func withLiveProviderSlot<T>(_ operation: () async throws -> T) async rethrows -> T {
        await E2ELiveProviderGate.shared.acquire()
        do {
            let result = try await operation()
            await E2ELiveProviderGate.shared.release()
            return result
        } catch {
            await E2ELiveProviderGate.shared.release()
            throw error
        }
    }
}

private actor E2ELiveProviderGate {
    static let shared = E2ELiveProviderGate()

    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum E2ETestSupportError: Error, CustomStringConvertible {
    case missingExecutable(String)

    var description: String {
        switch self {
        case .missingExecutable(let name):
            "Missing required E2E executable: \(name)"
        }
    }
}
