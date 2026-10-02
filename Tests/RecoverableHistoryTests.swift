import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRACore
import HostControlToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Recoverable task history")
@MainActor
struct RecoverableHistoryTests {
    @Test("Original evidence survives repeated summaries, provider switches and reopening the store")
    func evidenceSurvivesRestart() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.store")
        var container: ModelContainer? = try makeContainer(url: url)
        let identifiers: (task: UUID, event: UUID, run: UUID)
        let original = String(repeating: "Exact tool result 🧪\n", count: 800)
        do {
            let context = ModelContext(try #require(container))
            let workspace = Workspace(name: "Retention", primaryPath: root.path)
            let task = AgentTask(title: "History", goal: "Ship the current goal", workspace: workspace)
            context.insert(workspace); context.insert(task)
            let run = TaskRun(task: task)
            context.insert(run)
            let evidence = TaskEvent(task: task, type: "tool.result", payload: original, run: run,
                agentName: "researcher", agentId: "agent-1", teamName: "team-1")
            evidence.timestamp = Date(timeIntervalSince1970: 1)
            context.insert(evidence)
            identifiers = (task.id, evidence.id, run.id)
            for index in 0..<450 {
                let event = TaskEvent(task: task, type: "agent.response", payload: "filler \(index)")
                event.timestamp = Date(timeIntervalSince1970: Double(index + 2))
                context.insert(event)
            }
            // A pre-existing deletion summary is itself surviving evidence.
            let legacy = TaskEvent(task: task, type: "activity.compacted", payload: "Compacted 200 legacy events: only surviving evidence")
            context.insert(legacy)
            try context.save()
            for runtime in [AgentRuntimeID.claudeCode, .copilotCLI, .codexCLI, .claudeCode] {
                task.runtimeID = runtime.rawValue
                AgentEventCompactor.compactEvents(for: task, modelContext: context)
                try context.save()
            }
            #expect(task.events.count == 453)
            #expect(task.events.contains { $0.id == legacy.id && $0.payload == legacy.payload })
        }
        container = nil
        let reopened = try makeContainer(url: url)
        let reader = TaskHistoryEvidenceReader(container: reopened, taskID: identifiers.task)
        var cursor: String?
        var recoveredIDs: Set<String> = []
        repeat {
            let args: [String: Any] = cursor.map { ["before_id": $0] } ?? [:]
            let page = try reader.readHistory(try #require(TaskHistoryReadRequest.parse(args)))
            let events = try #require(page["events"] as? [[String: Any]])
            #expect(events.count <= 10)
            for event in events { recoveredIDs.insert(try #require(event["id"] as? String)) }
            cursor = page["next_before_id"] as? String
        } while cursor != nil
        #expect(recoveredIDs.count == 453)
        var restored = "", offset = 0
        repeat {
            let chunk = try reader.readHistory(try #require(TaskHistoryReadRequest.parse([
                "event_id": identifiers.event.uuidString, "offset": offset])))
            #expect(chunk["run_id"] as? String == identifiers.run.uuidString)
            #expect(chunk["agent_name"] as? String == "researcher")
            #expect(chunk["agent_id"] as? String == "agent-1")
            #expect(chunk["team_name"] as? String == "team-1")
            #expect(chunk["timestamp"] as? Double == 1)
            let text = try #require(chunk["payload"] as? String)
            #expect(text.count <= 4_000)
            restored += text
            offset = chunk["next_offset"] as? Int ?? 0
        } while offset > 0
        #expect(restored == original)
    }

    @Test("History MCP uses task-scoped reads and refuses private envelopes and arbitrary arguments")
    func brokerScopeAndValidation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Current", goal: "Current")
        let other = AgentTask(title: "Other", goal: "Other")
        context.insert(task); context.insert(other)
        let forbidden = TaskEvent(task: other, type: "tool.result", payload: "other task")
        let privateEvent = TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeResultCaptured, payload: "private launch envelope")
        let visible = TaskEvent(task: task, type: "tool.result", payload: "visible evidence")
        for event in [forbidden, privateEvent, visible] { context.insert(event) }
        try context.save()
        let reader = TaskHistoryEvidenceReader(container: container, taskID: task.id)
        let server = HostControlMCPServer(configuration: .init(allowedTools: ["history"]), historyReader: reader)
        let success = try call(server, arguments: [:])
        #expect(success.contains("visible evidence"))
        #expect(!success.contains("private launch envelope"))
        #expect(!success.contains("other task"))
        for id in [forbidden.id, privateEvent.id] {
            #expect(try call(server, arguments: ["event_id": id.uuidString]).contains("error"))
        }
        let invalidArguments: [[String: Any]] = [["task_id": other.id.uuidString], ["event_id": "../other"],
            ["offset": -1], ["offset": true], ["offset": 1.5], ["path": "/etc/passwd"],
            ["event_id": visible.id.uuidString, "before_id": visible.id.uuidString]]
        for invalid in invalidArguments {
            #expect(TaskHistoryReadRequest.parse(invalid) == nil)
            #expect(try call(server, arguments: invalid).contains("error"))
        }
        let unavailable = HostControlMCPServer(configuration: .init(allowedTools: ["history"]))
        #expect(try call(unavailable, arguments: [:]).contains("unavailable"))
        let denied = HostControlMCPServer(configuration: .init(allowedTools: ["jira"]), historyReader: reader)
        #expect(try call(denied, arguments: [:]).contains("not enabled"))
    }

    @Test("Five thousand events retain evidence while summary and provider pages remain bounded")
    func boundedWorkingSets() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Long task", goal: "Keep exact evidence")
        context.insert(task)
        var firstID: UUID?
        for index in 0..<5_000 {
            let event = TaskEvent(task: task, type: "tool.result", payload: "EXACT_RESULT_\(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index / 20))
            context.insert(event)
            if index == 0 { firstID = event.id }
        }
        try context.save()
        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()
        #expect(task.events.count == 5_001)
        let summary = try #require(task.events.first { $0.type == "activity.compacted" })
        #expect(summary.payload.contains("sample of 200"))
        #expect(summary.payload.count < 8_000)
        let reader = TaskHistoryEvidenceReader(container: container, taskID: task.id)
        let page = try reader.readHistory(try #require(TaskHistoryReadRequest.parse([:])))
        let events = try #require(page["events"] as? [[String: Any]])
        #expect(events.count == 10)
        let beforeID = try #require(page["next_before_id"] as? String)
        let next = try reader.readHistory(try #require(TaskHistoryReadRequest.parse(["before_id": beforeID])))
        let older = try #require(next["events"] as? [[String: Any]])
        #expect(Set(events.compactMap { $0["id"] as? String }).isDisjoint(with: older.compactMap { $0["id"] as? String }))
        let oldestID = try #require(firstID)
        let original = try reader.readHistory(try #require(TaskHistoryReadRequest.parse(["event_id": oldestID.uuidString])))
        #expect(original["payload"] as? String == "EXACT_RESULT_0")
        let store = TaskThreadHistoryStore(container: container)
        let refreshed = try await store.initialPage(taskID: task.id, coveringEventCount: 10,
            previousTotalEventCount: 0, eventPageSize: 10)
        #expect(refreshed.events.count == 20)
        #expect(refreshed.cursor.hasEarlierHistory)
    }

    @Test("Built CLI relay retrieves an exact payload through the broker transport")
    func cliTransport() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "CLI", goal: "Read history")
        context.insert(task)
        let event = TaskEvent(task: task, type: "tool.result", payload: "prefix EXACT_RELAY_EVIDENCE")
        context.insert(event)
        try context.save()
        let reader = TaskHistoryEvidenceReader(container: container, taskID: task.id)
        let server = HostControlMCPServer(configuration: .init(allowedTools: ["history"]), historyReader: reader)
        let token = HostControlBrokerFileDrop.newToken()
        let listener = HostControlBrokerDropListener(token: token, authorize: { _ in true },
            handle: { server.handleLine($0) ?? "" })
        let directory = try #require(listener.start(candidateDirectory: "/tmp/astra-history-cli-\(UUID().uuidString)"))
        defer { listener.invalidate() }
        let environment = [HostControlBrokerFileDrop.directoryEnvironmentKey: directory,
            HostControlBrokerFileDrop.tokenEnvironmentKey: token]
        let helper = try BuiltProductLocator.requiredExecutablePath(named: "astra-host-control")
        let result = await ProcessBinaryRunner().run(path: helper,
            args: ["history", "--event-id", event.id.uuidString, "--offset", "7"], timeout: 15, environment: environment)
        #expect(result.outcome == .exited(code: 0))
        #expect(result.stdout.contains("EXACT_RELAY_EVIDENCE"))
        #expect(!result.stdout.contains("prefix EXACT"))
        let invalid = await ProcessBinaryRunner().run(path: helper,
            args: ["history", "--event-id", event.id.uuidString, "--offset", "-1"], timeout: 15, environment: environment)
        #expect(invalid.outcome == .exited(code: 2))
    }

    @Test("Public summaries never expose private recovery envelope contents")
    func summaryExcludesRecoveryEnvelopes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Private recovery", goal: "Keep recovery private")
        context.insert(task)
        for type in [TaskEventTypes.System.runtimeResultCaptured, TaskEventTypes.System.runtimeOutcomePrepared] {
            let event = TaskEvent(task: task, eventType: type, payload: "Decision: PRIVATE_RECOVERY_DETAIL")
            event.timestamp = Date(timeIntervalSince1970: 1)
            context.insert(event)
        }
        for index in 0..<230 {
            let event = TaskEvent(task: task, type: "tool.result", payload: "result \(index)")
            event.timestamp = Date(timeIntervalSince1970: Double(index + 2))
            context.insert(event)
        }
        try context.save()
        AgentEventCompactor.compactEvents(for: task, modelContext: context)
        try context.save()
        let summary = try #require(task.events.first { $0.type == "activity.compacted" })
        #expect(!summary.payload.contains("PRIVATE_RECOVERY_DETAIL"))
        #expect(!summary.payload.contains("runtime.result.captured"))
        #expect(task.events.contains { $0.payload == "Decision: PRIVATE_RECOVERY_DETAIL" })
    }

    @Test("Current objective, newest direction, unfinished work and verification survive crowded history")
    func capsulePriority() {
        let lines = ["Context Capsule v2:", "Thread Intent:", "- Mode: execution",
            "Checkpoint:", "- old checkpoint " + String(repeating: "x", count: 4_000),
            "- Current objective: CURRENT_GOAL", "- Standing user instructions:",
            "  - NEWEST_DIRECTION", "  - " + String(repeating: "older directive ", count: 1_000),
            "- Constraints:", "  - NO_PUBLISH", "  - " + String(repeating: "constraint ", count: 1_000),
            "- Latest handoff: RUN_1", "- Handoff unfinished work:", "  - RETRY_FAILED_TEST",
            "- Verification: FAILED", "  - Verification command: swift test",
            "- Recent state turns:", "  - " + String(repeating: "old history ", count: 1_000)]
        let prompt = TaskContextPromptPriority.render(lines: lines, tail: "CANONICAL_STATE_POINTER", limit: 6_000)
        #expect(prompt.count <= 6_000)
        for marker in ["CURRENT_GOAL", "NEWEST_DIRECTION", "NO_PUBLISH", "RETRY_FAILED_TEST", "FAILED", "CANONICAL_STATE_POINTER"] {
            #expect(prompt.contains(marker))
        }
        #expect(prompt.contains("thread intent truncated"))
    }

    @Test("Fresh/native window selection and CLI history policy are explicit")
    func transportPolicy() {
        for runtime in [AgentRuntimeID.claudeCode, .codexCLI, .copilotCLI, .antigravityCLI, .openCodeCLI, .cursorCLI] {
            #expect(AgentPromptBuilder.continuityTranscriptWindow(for: runtime) == .extended)
            #expect(AgentPromptBuilder.continuityBudgetProfile(for: runtime) == .extendedTranscript)
        }
        #expect(AgentPromptBuilder.continuityTranscriptWindow(for: .claudeCode, usesNativeContinuation: true) == .standard)
        let descriptors = HostControlPlaneMCPProjection.runtimeSupportToolDescriptors(for: .claudeCode, tools: ["history"])
        #expect(descriptors.first?.allowedInputKeys == ["before_id", "event_id", "offset"])
        let id = UUID().uuidString
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control history"))
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control history --before-id \(id)"))
        #expect(HostControlCLIRelayPolicy.allows("astra-host-control history --event-id \(id) --offset 4000"))
        for invalid in ["--offset -1", "--offset 1", "--task-id \(id)", "--event-id ../secret", "--event-id \(id) --offset 1.5"] {
            #expect(!HostControlCLIRelayPolicy.allows("astra-host-control history \(invalid)"))
        }
    }

    private func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: [configuration])
    }

    private func call(_ server: HostControlMCPServer, arguments: [String: Any]) throws -> String {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "history", "arguments": arguments]]
        return try #require(server.handleLine(String(decoding: JSONSerialization.data(withJSONObject: request), as: UTF8.self)))
    }
}
