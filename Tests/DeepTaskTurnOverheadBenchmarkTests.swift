import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// ASTRA's own share of one follow-up turn on a deep task, by segment.
///
/// Explicitly opt in: one disk-backed fixture, a fake provider that answers in
/// milliseconds, no user data. Every turn — the seeded history included — goes
/// through the real worker, so runs, events, handoffs, checkpoints, session
/// history and `current_state.json` grow the way they do in production. The
/// shape follows the production task this was measured against (38 prior
/// runs, ~2 100 events, ~50 output files).
@MainActor
@Suite("Deep task turn overhead", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["DEEP_TURN_BENCHMARK"] == "1"))
struct DeepTaskTurnOverheadBenchmarkTests {
    @Test func followUpOnDeepTask() async throws {
        let depth = Int(ProcessInfo.processInfo.environment["DEEP_TURN_BENCHMARK_DEPTH"] ?? "") ?? 40
        let measured = Int(ProcessInfo.processInfo.environment["DEEP_TURN_BENCHMARK_SAMPLES"] ?? "") ?? 5
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }

        let task = harness.makeTask(runtime: .claudeCode, goal: "Analyse the cohort and keep the report current",
                                    model: "claude-sonnet-4-6")
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: HeadlessChatScenarioTests.claudeScript(body: Self.providerBody(
                taskFolder: taskFolder, counter: harness.rootURL.appendingPathComponent("turns").path
            ))
        )
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.execute(task: task, worker: worker)
        for turn in 1..<depth {
            let started = ContinuousClock.now
            _ = await harness.continueTask(task: task, message: "Follow-up \(turn): refine the report", worker: worker)
            if turn.isMultiple(of: 10) {
                print("[deep-turn-seed] depth=\(turn) wall_ms=\(Self.milliseconds(ContinuousClock.now - started))")
            }
        }
        #expect(task.runs.count == depth)

        var samples: [Segments] = []
        // Lets an external `sample <pid>` attach to exactly the measured turns.
        print("[deep-turn-measure-start] pid=\(ProcessInfo.processInfo.processIdentifier)")
        for sample in 0..<measured {
            let capture = TimelineCapture(taskID: task.id)
            let started = Date()
            let startedCPU = mainThreadCPUMilliseconds()
            _ = await harness.continueTask(task: task, message: "Measured follow-up \(sample)", worker: worker)
            let ended = Date()
            let endedCPU = mainThreadCPUMilliseconds()
            let segments = try #require(Segments(entries: capture.entries, started: started, ended: ended,
                                                 startedCPU: startedCPU, endedCPU: endedCPU))
            samples.append(segments)
            print("[deep-turn] sample=\(sample) prior_runs=\(depth + sample) \(segments.summary)")
            if sample == measured - 1 {
                for line in capture.timeline(since: started) { print("[deep-turn-timeline] \(line)") }
            }
        }
        #expect(task.status == .completed)
        print("[deep-turn] median prior_runs=\(depth) events=\(task.events.count) artifacts=\(task.artifacts.count) "
            + Segments.median(samples).summary)
    }

    /// One turn's worth of provider output: a short answer, tool calls that
    /// grow the event log, and one new file in the task folder.
    private static func providerBody(taskFolder: String, counter: String) -> String {
        let quotedCounter = HeadlessChatScenarioTests.shQuoteSandboxPath(counter)
        let quotedFolder = HeadlessChatScenarioTests.shQuoteSandboxPath(taskFolder)
        let paragraph = String(repeating: "The cohort summary is unchanged except for the refined counts. ", count: 36)
        var lines = [
            "n=$(cat \(quotedCounter) 2>/dev/null || echo 0); n=$((n+1)); echo $n > \(quotedCounter)",
            "mkdir -p \(quotedFolder)/outputs",
            "printf '# Report %s\\n\\n%s\\n' \"$n\" 'Synthetic report body.' > \(quotedFolder)/outputs/report_$n.md",
            #"printf '%s\n' '{"type":"system","subtype":"init","session_id":"deep-session","model":"claude-sonnet-4-6"}'"#
        ]
        for call in 0..<12 {
            lines.append(#"printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","id":"tool_\#(call)","name":"Read","input":{"file_path":"README.md"}}]}}'"#)
            lines.append(#"printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool_\#(call)","content":"line one\nline two"}]}}'"#)
        }
        lines.append(#"printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"\#(paragraph)"}]}}'"#)
        lines.append(#"printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"\#(paragraph)","usage":{"input_tokens":3,"output_tokens":5}}'"#)
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    fileprivate static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Wall-clock split of one turn. The provider boundary is the two log
    /// lines the process runner writes around the child: `runtime.provider_detected`
    /// immediately before the spawn and `worker.exited` when it is reaped.
    ///
    /// Wall clock moves with machine load, so each segment also carries the
    /// main thread's CPU time over the same stretch — the actor this pipeline
    /// runs on, and the number a busy machine does not inflate. It is read at
    /// the boundary lines, which the main actor logs.
    struct Segments {
        let preLaunchMilliseconds: Int
        let providerMilliseconds: Int
        let settleMilliseconds: Int
        let preLaunchCPUMilliseconds: Int
        let settleCPUMilliseconds: Int
        var totalMilliseconds: Int { preLaunchMilliseconds + providerMilliseconds + settleMilliseconds }
        var astraMilliseconds: Int { preLaunchMilliseconds + settleMilliseconds }
        var astraCPUMilliseconds: Int { preLaunchCPUMilliseconds + settleCPUMilliseconds }

        init(preLaunch: Int, provider: Int, settle: Int, preLaunchCPU: Int, settleCPU: Int) {
            preLaunchMilliseconds = preLaunch
            providerMilliseconds = provider
            settleMilliseconds = settle
            preLaunchCPUMilliseconds = preLaunchCPU
            settleCPUMilliseconds = settleCPU
        }

        fileprivate init?(entries: [TimelineCapture.Line], started: Date, ended: Date, startedCPU: Double, endedCPU: Double) {
            guard let spawn = entries.first(where: { $0.entry.message.hasPrefix("runtime.provider_detected") }),
                  let exit = entries.last(where: { $0.entry.message.hasPrefix("worker.exited") }),
                  let spawnCPU = spawn.mainThreadCPUMilliseconds,
                  let exitCPU = entries.first(where: {
                      $0.entry.timestamp >= exit.entry.timestamp && $0.mainThreadCPUMilliseconds != nil
                  })?.mainThreadCPUMilliseconds else { return nil }
            self.init(preLaunch: Int(spawn.entry.timestamp.timeIntervalSince(started) * 1_000),
                      provider: Int(exit.entry.timestamp.timeIntervalSince(spawn.entry.timestamp) * 1_000),
                      settle: Int(ended.timeIntervalSince(exit.entry.timestamp) * 1_000),
                      preLaunchCPU: Int(spawnCPU - startedCPU),
                      settleCPU: Int(endedCPU - exitCPU))
        }

        var summary: String {
            "pre_launch_ms=\(preLaunchMilliseconds) provider_ms=\(providerMilliseconds) "
                + "settle_ms=\(settleMilliseconds) astra_ms=\(astraMilliseconds) total_ms=\(totalMilliseconds) "
                + "main_cpu_pre_launch_ms=\(preLaunchCPUMilliseconds) main_cpu_settle_ms=\(settleCPUMilliseconds) "
                + "main_cpu_astra_ms=\(astraCPUMilliseconds)"
        }

        static func median(_ samples: [Segments]) -> Segments {
            func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            return Segments(preLaunch: median(samples.map(\.preLaunchMilliseconds)),
                            provider: median(samples.map(\.providerMilliseconds)),
                            settle: median(samples.map(\.settleMilliseconds)),
                            preLaunchCPU: median(samples.map(\.preLaunchCPUMilliseconds)),
                            settleCPU: median(samples.map(\.settleCPUMilliseconds)))
        }
    }
}

/// Collects this task's log lines as they are written. The post is synchronous
/// on the logging thread and other suites log concurrently, hence the lock.
private final class TimelineCapture: @unchecked Sendable {
    struct Line {
        let entry: LogEntry
        /// Set only for lines logged on the main thread.
        let mainThreadCPUMilliseconds: Double?
    }

    private let lock = NSLock()
    private var collected: [Line] = []
    private var observer: (any NSObjectProtocol)?

    init(taskID: UUID) {
        observer = NotificationCenter.default.addObserver(forName: .appLoggerDidAppendEntry, object: nil, queue: nil) {
            [weak self] notification in
            guard let self, let entry = notification.userInfo?["entry"] as? LogEntry,
                  entry.taskID == taskID || entry.taskID == nil else { return }
            let cpu = Thread.isMainThread ? mainThreadCPUMilliseconds() : nil
            self.lock.lock()
            defer { self.lock.unlock() }
            self.collected.append(Line(entry: entry, mainThreadCPUMilliseconds: cpu))
        }
    }

    var entries: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return collected.filter { $0.entry.taskID != nil }
    }

    /// Every line with the gap since the previous one, so the expensive stretch
    /// between two log lines stands out.
    func timeline(since start: Date) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var previous = start
        return collected.map { line in
            let entry = line.entry
            let text = String(format: "+%6.0f ms (gap %5.0f) cpu=%@ [%@] %@",
                              entry.timestamp.timeIntervalSince(start) * 1_000,
                              entry.timestamp.timeIntervalSince(previous) * 1_000,
                              line.mainThreadCPUMilliseconds.map { String(format: "%.0f", $0) } ?? "-",
                              entry.category, String(entry.message.prefix(150)))
            previous = entry.timestamp
            return text
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// CPU time of the calling thread. Called on the main thread, it is the main
/// actor's own work, whatever else the machine is doing.
private func mainThreadCPUMilliseconds() -> Double {
    let port = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, port) }
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.user_time.seconds + info.system_time.seconds) * 1_000
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000
}
