import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Headless Chat Scenarios", .serialized)
@MainActor
struct HeadlessChatScenarioTests {
}

extension HeadlessChatScenarioTests {
    static func copilotScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuoteSandboxPath($0.path))" } ?? ""
        return """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --available-tools=TOOLS --excluded-tools=TOOLS
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        \(recordArgs)
        \(body)
        """
    }

    static func claudeScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuoteSandboxPath($0.path))" } ?? ""
        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "claude fake 1.0"
          exit 0
        fi
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf '%s\\n' '{"loggedIn":true}'
          exit 0
        fi
        \(recordArgs)
        \(body)
        """
    }

    static func antigravityScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuoteSandboxPath($0.path))" } ?? ""
        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' '1.0.3'
          exit 0
        fi
        if [ "$1" = "--print" ] && [ "$2" = "Reply with ASTRA_READY only." ]; then
          printf '%s\\n' 'ASTRA_READY'
          exit 0
        fi
        \(recordArgs)
        \(body)
        """
    }

    static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func shQuoteSandboxPath(_ value: String) -> String {
        shQuote(ExecutionSandbox.canonicalize(value) ?? value)
    }

    static func argumentValues(after flag: String, in arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: flag) else { return [] }
        let start = arguments.index(after: index)
        guard start < arguments.endIndex else { return [] }
        return Array(arguments[start...].prefix { !$0.hasPrefix("--") })
    }
}

@MainActor
final class HeadlessChatHarness {
    let rootURL: URL
    let workspaceURL: URL
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-headless-chat-\(UUID().uuidString)", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        context = container.mainContext
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writeExecutable(named name: String, script: String) throws -> String {
        let url = rootURL.appendingPathComponent(name)
        try scriptByAddingHeadlessReadinessProbeResponses(named: name, script: script)
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func scriptByAddingHeadlessReadinessProbeResponses(named name: String, script: String) -> String {
        let probeBody: String
        switch name {
        case "claude":
            probeBody = """
            if [ "$1" = "--version" ]; then
              echo "claude fake 1.0"
              exit 0
            fi
            if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
              printf '%s\\n' '{"loggedIn":true}'
              exit 0
            fi
            """
        case "agy":
            probeBody = """
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            if [ "$1" = "--print" ] && [ "$2" = "Reply with ASTRA_READY only." ]; then
              printf '%s\\n' 'ASTRA_READY'
              exit 0
            fi
            """
        case "opencode":
            probeBody = """
            if [ "$1" = "--version" ]; then
              echo "opencode fake 1.0"
              exit 0
            fi
            if [ "$1" = "auth" ] && [ "$2" = "list" ]; then
              printf '%s\\n' '1 credential'
              exit 0
            fi
            """
        case "codex":
            probeBody = """
            if [ "$1" = "--version" ]; then
              echo "codex fake 1.0"
              exit 0
            fi
            if [ "$1" = "login" ] && [ "$2" = "status" ]; then
              printf '%s\\n' 'Logged in'
              exit 0
            fi
            """
        case "cursor-agent":
            probeBody = """
            if [ "$1" = "--version" ]; then
              echo "cursor-agent fake 1.0"
              exit 0
            fi
            if [ "$1" = "status" ]; then
              printf '%s\\n' 'Authenticated'
              exit 0
            fi
            """
        default:
            return script
        }

        guard script.hasPrefix("#!") else {
            return "#!/bin/sh\n\(probeBody)\n\(script)"
        }
        var lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shebang = lines.removeFirst()
        return ([shebang, probeBody] + lines).joined(separator: "\n")
    }

    func makeTask(
        runtime: AgentRuntimeID,
        goal: String,
        model: String,
        tokenBudget: Int? = nil
    ) -> AgentTask {
        // Fake provider scripts in this harness intentionally write argv,
        // counters, and launch markers under `rootURL`. Register that temp
        // support directory as an explicit additional path so strict/autonomous
        // sandbox runs model the same declared-path contract production uses.
        let workspace = Workspace(
            name: "Headless",
            primaryPath: workspaceURL.path,
            additionalPaths: [rootURL.path]
        )
        context.insert(workspace)
        let resolvedBudget = tokenBudget ?? (runtime == .claudeCode ? 200_000 : 1_000)

        let task = AgentTask(
            title: "Headless \(runtime.rawValue)",
            goal: goal,
            workspace: workspace,
            tokenBudget: resolvedBudget,
            model: model
        )
        task.runtimeID = runtime.rawValue
        task.status = .queued
        context.insert(task)
        try? context.save()
        return task
    }

    func makeWorker(
        runtime: AgentRuntimeID,
        executablePath: String,
        permissionPolicy: PermissionPolicy = .restricted,
        liveApprovals: Bool = false
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker.scenarioWorker()
        worker.timeoutSeconds = 10
        worker.permissionPolicy = permissionPolicy
        // Most scenario fakes assert on argv prompt delivery; live approvals
        // switch Claude to stdin delivery, so tests opt in explicitly.
        worker.liveApprovalsEnabled = liveApprovals
        switch runtime {
        case .claudeCode:
            worker.claudePath = executablePath
        case .copilotCLI:
            worker.copilotPath = executablePath
            worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        default:
            worker.setExecutablePath(executablePath, for: runtime)
            worker.setHomeDirectory(
                rootURL.appendingPathComponent("\(runtime.rawValue)-home", isDirectory: true).path,
                for: runtime
            )
        }
        return worker
    }

    func makeWorker(
        claudePath: String,
        copilotPath: String,
        permissionPolicy: PermissionPolicy = .restricted
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker.scenarioWorker()
        worker.timeoutSeconds = 10
        worker.permissionPolicy = permissionPolicy
        worker.liveApprovalsEnabled = false
        worker.claudePath = claudePath
        worker.copilotPath = copilotPath
        worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        return worker
    }

    func execute(task: AgentTask, worker: AgentRuntimeWorker) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: context)
        await worker.execute(task: task, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func continueTask(
        task: AgentTask,
        message: String,
        worker: AgentRuntimeWorker,
        executionPolicy: AgentRuntimeExecutionPolicy = .default
    ) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(
            task: task,
            message: message,
            modelContext: context,
            executionPolicy: executionPolicy
        ) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func executeApprovedPlan(
        task: AgentTask,
        plan: TaskPlanPayload,
        worker: AgentRuntimeWorker,
        mode: TaskPlanExecutionMode = .fullPlan
    ) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        DirectWorkerLaunchAdmission.admitApprovedPlanRun(task, modelContext: context)
        await worker.executeApprovedPlan(task: task, plan: plan, mode: mode, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func waitUntil(
        task: AgentTask,
        timeoutSeconds: TimeInterval = 3,
        predicate: @escaping (AgentTask) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate(task) {
                return true
            }
            try? await Swift.Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate(task)
    }
}
