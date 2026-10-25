import Foundation
import Testing
import ASTRACore
@testable import ASTRA

private final class SupervisionTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var values: [RuntimeSupervisionReport] = []
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    var reports: [RuntimeSupervisionReport] { lock.lock(); defer { lock.unlock() }; return values }
    func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
    func record(_ report: RuntimeSupervisionReport) { lock.lock(); values.append(report); lock.unlock() }
}

private actor SupervisionTestGate {
    private var waiter: CheckedContinuation<RuntimeSupervisionAssessment, Never>?
    var started: Bool { waiter != nil }
    func wait() async -> RuntimeSupervisionAssessment {
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ assessment: RuntimeSupervisionAssessment) { waiter?.resume(returning: assessment); waiter = nil }
}

@Suite("Shared runtime supervision")
struct RuntimeSupervisionTests {
    private func observation(_ revision: Int = 0) -> RuntimeSupervisionObservation {
        .init(progressRevision: revision, quietSeconds: 600, stdoutBytes: 10, stderrBytes: 20,
              unknownFrames: 0, activeTools: [], managedJobs: [], recentOutput: "No answer yet")
    }
    private func session(_ state: SupervisionTestState, files: RuntimeSupervisionFiles = .init(),
                         reserve: @escaping @Sendable (Int) -> Bool = { _ in true },
                         investigate: @escaping RuntimeSupervisionSession.Investigator) -> RuntimeSupervisionSession {
        .init(goal: "Create report", runtime: "fixture", remoteCoverage: "Unavailable", baseline: .init(),
              configuration: .init(investigationSeconds: 5, recheckSeconds: 10, maximumInvestigations: 2, tokenReservation: 100),
              now: { state.now }, collectFiles: { files }, investigate: investigate,
              reserveTokens: reserve, report: { state.record($0) })
    }
    private func waitFor(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }

    @Test("Silence launches an independent investigation once while the provider keeps running")
    func quietCheckAndStall() async throws {
        let state = SupervisionTestState(), gate = SupervisionTestGate()
        let session = session(state) { _ in await gate.wait() }
        #expect(session.tick(observation(), investigationDue: true) == .keepRunning)
        #expect(session.tick(observation(), investigationDue: true) == .keepRunning)
        #expect(state.reports.count == 1)
        try await waitFor { await gate.started }
        await gate.finish(.init(assessment: .suspectedStalled, explanation: "The known operation has not advanced.", evidenceIDs: ["runtime"]))
        try await waitFor { if case .stop = session.tick(observation(), investigationDue: true) { return true }; return false }
        guard case .stop(let reason, _) = session.tick(observation(), investigationDue: true) else { Issue.record("Expected a supervised stop"); return }
        #expect(reason == "provider_supervisor_stalled")
        #expect(session.hasCompletedInvestigation(at: 0))
        #expect(!session.hasCompletedInvestigation(at: 1))
        #expect(session.tokenReservation == 100)
        session.finish()
        #expect(!session.hasCompletedInvestigation(at: 0))
    }

    @Test("New progress and cancellation invalidate a late model verdict", arguments: [false, true])
    func staleVerdict(cancel: Bool) async throws {
        let state = SupervisionTestState(), gate = SupervisionTestGate()
        let session = session(state) { _ in await gate.wait() }
        _ = session.tick(observation(), investigationDue: true)
        try await waitFor { await gate.started }
        if cancel { session.finish() }
        else { #expect(session.tick(observation(1), investigationDue: false) == .keepRunning) }
        await gate.finish(.init(assessment: .suspectedStalled, explanation: "Old observation", evidenceIDs: ["runtime"]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!state.reports.contains { $0.phase == .stopping })
        #expect(session.tick(observation(1), investigationDue: false) == .keepRunning)
        session.finish()
    }

    @Test("Files or coverage changing during model assessment invalidate its earlier stall verdict", arguments: [false, true])
    func filesChangeDuringAssessment(initiallyUnavailable: Bool) async throws {
        let state = SupervisionTestState(), gate = SupervisionTestGate()
        let changed = AgentLockedBuffer()
        let session = RuntimeSupervisionSession(goal: "Create report", runtime: "fixture",
            remoteCoverage: "Unknown", baseline: .init(),
            collectFiles: {
                changed.value.isEmpty ? .init(unavailable: initiallyUnavailable ? "Initial stat unavailable" : nil)
                    : .init(metadata: ["report.md": "\(Date().timeIntervalSince1970)|0|10|1"])
            }, investigate: { _ in await gate.wait() }, reserveTokens: { _ in true }, report: { state.record($0) })
        _ = session.tick(observation(), investigationDue: true)
        try await waitFor { await gate.started }
        changed.append("yes")
        await gate.finish(.init(assessment: .suspectedStalled, explanation: "Old file snapshot was empty", evidenceIDs: ["files"]))
        try await waitFor {
            state.reports.contains { $0.phase == .inconclusive } || session.tick(observation(), investigationDue: false) != .keepRunning
        }
        #expect(session.tick(observation(), investigationDue: false) == .keepRunning)
        #expect(state.reports.contains { $0.phase == .inconclusive && $0.message.contains("changed during") })
        #expect(state.reports.last?.evidence?.postAssessmentFileChanges == (initiallyUnavailable ? [] : ["report.md"]))
        session.finish()
    }

    @Test("A hung investigator cannot hold the watchdog past its deadline")
    func investigatorDeadline() async throws {
        let state = SupervisionTestState(), gate = SupervisionTestGate()
        let session = session(state) { _ in await gate.wait() }
        _ = session.tick(observation(), investigationDue: true)
        try await waitFor { await gate.started }
        state.advance(6)
        guard case .stop(let reason, _) = session.tick(observation(), investigationDue: true) else { Issue.record("Deadline did not stop the attempt"); return }
        #expect(reason == "provider_supervision_inconclusive")
        await gate.finish(.init(assessment: .progressing, explanation: "Late answer", evidenceIDs: ["files"]))
        session.finish()
    }

    @Test("Unsupported progress claims become unknown, and repeated checks remain bounded")
    func unsupportedProgress() async throws {
        let state = SupervisionTestState()
        let session = session(state) { _ in .init(assessment: .progressing, explanation: "It must be working", evidenceIDs: ["files"]) }
        for n in 1...2 {
            _ = session.tick(observation(), investigationDue: true)
            try await waitFor { state.reports.filter { $0.phase == .inconclusive }.count == n }
            if n == 1 {
                #expect(state.reports.last?.message.contains("check again in 10 seconds") == true)
            } else {
                #expect(state.reports.last?.message.contains("before stopping this attempt") == true)
                #expect(state.reports.last?.message.contains("checking again") == false)
            }
            state.advance(11)
        }
        guard case .stop = session.tick(observation(), investigationDue: true) else { Issue.record("Unbounded model extensions"); return }
        #expect(session.tokenReservation == 200)
        session.finish()
    }

    @Test("Real progress starts a new quiet episode without refunding earlier investigation costs")
    func separateQuietEpisodes() async throws {
        let state = SupervisionTestState()
        let session = session(state) { _ in .inconclusive("Insufficient evidence") }
        for count in 1...2 {
            _ = session.tick(observation(), investigationDue: true)
            try await waitFor { state.reports.filter { $0.phase == .inconclusive }.count == count }
            state.advance(11)
        }
        _ = session.tick(observation(1), investigationDue: false)
        _ = session.tick(observation(1), investigationDue: true)
        try await waitFor { state.reports.filter { $0.phase == .inconclusive }.count == 3 }
        #expect(session.tokenReservation == 300)
        session.finish()
    }

    @Test("Missing budget does not invoke the model")
    func noBudget() {
        let state = SupervisionTestState()
        let session = session(state, reserve: { _ in false }) { _ in Issue.record("Model invoked without budget"); return .inconclusive("Unexpected") }
        guard case .stop(let reason, _) = session.tick(observation(), investigationDue: true) else { Issue.record("Expected bounded fallback"); return }
        #expect(reason == "provider_supervision_budget_unavailable")
        #expect(session.tokenReservation == 0)
    }

    @Test("Investigation reservations count alongside reported provider usage")
    func sharedBudget() {
        let monitor = AgentProcessMonitor(tokenBudget: 100)
        #expect(monitor.reserveSupervisionTokens(90))
        #expect(!monitor.reserveSupervisionTokens(20))
        #expect(monitor.processEvent(.usage(totalInputTokens: 15, totalOutputTokens: 10), process: nil))
        #expect(monitor.budgetExceeded)
        let unlimited = AgentProcessMonitor(tokenBudget: Int.max)
        #expect(unlimited.reserveSupervisionTokens(100))
        #expect(unlimited.processEvent(.usage(totalInputTokens: Int.max, totalOutputTokens: 0), process: nil))
        #expect(unlimited.budgetExceeded)
    }

    @Test("Hard budget and wall-clock limits win while an investigation is pending", arguments: [false, true])
    func hardStops(wallClock: Bool) async throws {
        let state = SupervisionTestState(), gate = SupervisionTestGate()
        let session = session(state) { _ in await gate.wait() }
        let monitor = AgentProcessMonitor(tokenBudget: 100, idleTimeoutSeconds: 0,
            noSemanticProgressTimeoutSeconds: 0, maxRunSeconds: wallClock ? 0.5 : 100)
        monitor.supervision = session
        #expect(!monitor.evaluateWatchdogTimeoutForTesting())
        try await waitFor { await gate.started }
        if wallClock {
            try await Task.sleep(for: .milliseconds(550))
            #expect(monitor.evaluateWatchdogTimeoutForTesting())
            #expect(monitor.runtimeStopReason == "provider_run_wall_clock_exceeded")
        } else {
            #expect(monitor.processEvent(.usage(totalInputTokens: 101, totalOutputTokens: 0), process: nil))
            #expect(monitor.budgetExceeded)
        }
        session.finish()
        await gate.finish(.inconclusive("Cancelled check"))
        #expect(!state.reports.contains { $0.phase == .stopping })
    }

    @Test("An answer arriving after the deadline cannot buy another waiting interval")
    func lateAnswerBeforeTick() async throws {
        let state = SupervisionTestState(), gate = SupervisionTestGate()
        let session = session(state) { _ in await gate.wait() }
        _ = session.tick(observation(), investigationDue: true)
        try await waitFor { await gate.started }
        state.advance(6)
        await gate.finish(.inconclusive("Need more time"))
        try await Task.sleep(for: .milliseconds(20))
        guard case .stop(let reason, _) = session.tick(observation(), investigationDue: true) else {
            Issue.record("Late answer extended the deadline"); return
        }
        #expect(reason == "provider_supervision_inconclusive")
        #expect(!state.reports.contains { $0.phase == .inconclusive })
        session.finish()
    }

    @Test("Progress between the verdict and stop invalidates the verdict without a false stopping message")
    func progressBeforeStop() async throws {
        let state = SupervisionTestState()
        let session = session(state) { _ in .init(assessment: .suspectedStalled, explanation: "No progress", evidenceIDs: ["runtime"]) }
        _ = session.tick(observation(), investigationDue: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.tick(observation(1), investigationDue: false) == .keepRunning)
        session.confirmStop()
        #expect(!state.reports.contains { $0.phase == .stopping })
        for revision in 2...20 { _ = session.tick(observation(revision), investigationDue: false) }
        #expect(state.reports.filter { $0.phase == .resumed }.count == 1)
        session.finish()
    }

    @Test("Fresh file evidence extends a quiet run; old changes do not", arguments: [0, 300])
    func fileFreshness(age: Int) async throws {
        let state = SupervisionTestState()
        let changed = Int(Date().timeIntervalSince1970) - age
        let files = RuntimeSupervisionFiles(metadata: ["report.md": "\(changed)|\(changed)|42|1"])
        let session = session(state, files: files) { evidence in
            #expect(evidence.changedFiles.first?.currentBytes == 42)
            return .init(assessment: .progressing, explanation: "The report is growing", evidenceIDs: ["files"])
        }
        _ = session.tick(observation(), investigationDue: true)
        let phase: RuntimeSupervisionReport.Phase = age == 0 ? .progressing : .inconclusive
        try await waitFor { state.reports.contains { $0.phase == phase } }
        #expect(session.tick(observation(), investigationDue: true) == .keepRunning)
        session.finish()
    }

    @Test("Known waits are reported honestly and do not launch repeated checks within the grace interval")
    func knownWait() async throws {
        let state = SupervisionTestState()
        let session = session(state) { _ in .init(assessment: .waiting, explanation: "A tool is still open; completion is unknown", evidenceIDs: ["runtime"]) }
        var evidence = observation()
        evidence.activeTools = ["tool-1"]
        _ = session.tick(evidence, investigationDue: true)
        try await waitFor { state.reports.contains { $0.phase == .waiting } }
        for _ in 0...10 { _ = session.tick(evidence, investigationDue: true) }
        #expect(state.reports.filter { $0.phase == .checking }.count == 1)
        session.finish()
    }

    @Test("File activity before the silence window does not support continued progress")
    func silenceWindowFiles() {
        let files = RuntimeSupervisionFiles(metadata: ["old.md": "100|100|10|1", "new.md": "190|190|20|2"])
        #expect(files.recentChanges(since: .init(), quietSeconds: 20, now: Date(timeIntervalSince1970: 200)) == ["new.md"])
        #expect(files.recentChanges(since: .init(unavailable: "Missing baseline"), quietSeconds: 20).isEmpty)
    }

    @Test("A renewed managed-job heartbeat invalidates an in-flight stall investigation")
    func renewedHeartbeat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-heartbeat-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let heartbeat = root.appendingPathComponent("heartbeat.json")
        let stale = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -120))
        try #"{"status":"running","timestamp":"\#(stale)"}"#.write(to: heartbeat, atomically: true, encoding: .utf8)
        let monitor = AgentProcessMonitor(tokenBudget: Int.max, idleTimeoutSeconds: 60,
            noSemanticProgressTimeoutSeconds: 60, managedWorkspaceJobIdleTimeoutSeconds: 60)
        _ = monitor.processEvent(.toolResult(toolId: "job-start", content: """
            job_id: job-1
            status: running
            runtime: docker
            heartbeat: \(heartbeat.path)
            """), process: nil)
        let state = SupervisionTestState(), gate = SupervisionTestGate()
        let session = session(state) { _ in await gate.wait() }
        monitor.supervision = session
        #expect(!monitor.evaluateWatchdogTimeoutForTesting())
        try await waitFor { await gate.started }
        let fresh = ISO8601DateFormatter().string(from: Date())
        try #"{"status":"running","timestamp":"\#(fresh)"}"#.write(to: heartbeat, atomically: true, encoding: .utf8)
        #expect(!monitor.evaluateWatchdogTimeoutForTesting())
        await gate.finish(.init(assessment: .suspectedStalled, explanation: "Old heartbeat", evidenceIDs: ["runtime"]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!monitor.evaluateWatchdogTimeoutForTesting())
        #expect(monitor.runtimeStopReason == nil)
        #expect(state.reports.contains { $0.phase == .resumed })
        session.finish()
    }

    @Test("Malformed, oversized and invented evidence are rejected")
    func strictAssessment() {
        #expect(RuntimeSupervisionAssessment.decode("not JSON") == nil)
        #expect(RuntimeSupervisionAssessment.decode(#"{"assessment":"progressing","explanation":"yes","evidenceIDs":["invented"]}"#) == nil)
        #expect(RuntimeSupervisionAssessment.decode(#"{"assessment":"inconclusive","explanation":"Remote evidence is unavailable","evidenceIDs":["remote"]}"#)?.assessment == .inconclusive)
    }

    @Test("Every supervisor stop is terminal rather than an approval wait")
    @MainActor func terminalReasons() {
        for reason in ["provider_supervisor_stalled", "provider_recovery_failed", "provider_supervision_inconclusive", "provider_supervision_budget_unavailable"] {
            #expect(AgentRuntimeWorker.isTerminalRuntimeStop(reason))
        }
    }
}
