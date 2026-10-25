import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("OpenCode natural completion proof", .serialized)
struct OpenCodeCompletionProofTests {
    private let stop = #"{"type":"step_finish","sessionID":"s","part":{"type":"step-finish","sessionID":"s","id":"p","messageID":"m","reason":"stop","tokens":{"input":1,"output":2}}}"#
    private func observe(_ line: String, in evidence: RuntimeExecutionProcessEvidence) {
        evidence.observeFrame(line, parsesJSONLines: true, events: OpenCodeStreamEventParser.parseAll(line: line))
    }

    @Test("A final step needs both natural successful exit and complete stdout", arguments: [false, true], [false, true])
    func exitContract(natural: Bool, eof: Bool) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .openCodeCLI)
        observe(stop, in: evidence)
        #expect(!evidence.toolsStopped)
        evidence.processExited(naturally: natural, stdoutEOF: eof)
        #expect(evidence.toolsStopped == (natural && eof))
    }

    @Test("Any subsequent work, missing finish, or uncertain execution blocks completion", arguments: [
        #"{"type":"step_start","sessionID":"s","part":{"type":"step-start","sessionID":"s","id":"p2","messageID":"m2"}}"#,
        #"{"type":"text","sessionID":"s","part":{"type":"text","sessionID":"s","id":"p2","messageID":"m2","text":"more"}}"#,
        #"{"type":"reasoning","sessionID":"s","part":{"type":"reasoning","sessionID":"s","id":"p2","messageID":"m2","text":"more"}}"#,
        #"{"type":"permission.asked","sessionID":"s","properties":{"permission":"bash"}}"#,
        #"{"type":"tool_use","sessionID":"s","part":{"type":"tool","tool":"bash","state":{"status":"completed","output":"done"}}}"#,
        #"{"type":"step_finish","sessionID":"s","part":{"type":"step-finish","sessionID":"s","id":"p","messageID":"m","reason":"tool-calls"}}"#,
        #"{"type":"step_finish","sessionID":"s","part":{"type":"step-finish","sessionID":"other","id":"p","messageID":"m","reason":"stop"}}"#
    ])
    func laterWork(line: String) {
        let evidence = RuntimeExecutionProcessEvidence(runtime: .openCodeCLI)
        observe(stop, in: evidence)
        observe(line, in: evidence)
        evidence.processExited(naturally: true, stdoutEOF: true)
        #expect(!evidence.toolsStopped)
        let missing = RuntimeExecutionProcessEvidence(runtime: .openCodeCLI)
        missing.processExited(naturally: true, stdoutEOF: true)
        #expect(!missing.toolsStopped)
    }

    @Test("waitpid retains a natural exit even if cancellation arrives after reap")
    func lateStop() async throws {
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: ["-c", "exit 0"],
            currentDirectory: "/tmp", environment: [:])
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        #expect(status == 0)
        process.terminate()
        #expect(process.naturalSuccessfulExit)
        let reader = AgentProcessPipeReader(process.stdoutFileHandle)
        #expect(reader.finish { _ in })
    }

    @Test("A live pipe writer prevents EOF certification without blocking completion")
    func heldPipe() throws {
        let pipe = Pipe()
        let reader = AgentProcessPipeReader(pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("last frame".utf8))
        var bytes = Data()
        #expect(!reader.finish { bytes.append($0) })
        #expect(String(decoding: bytes, as: UTF8.self) == "last frame")
        try pipe.fileHandleForWriting.close()
        #expect(!reader.finish { _ in })
    }

    @Test("A SIGTERM handler returning zero is not natural completion")
    func gracefulStopIsNotNaturalExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("natural-exit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh",
            arguments: ["-c", "trap 'exit 0' TERM; touch ready; while :; do sleep 0.1; done"],
            currentDirectory: root.path, environment: [:])
        let completion = Task {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(returning: -1) }
            }
        }
        defer { process.terminate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        _ = process.requestGracefulStop()
        let breaker = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { process.terminate() } }
        let status = await completion.value
        breaker.cancel()
        #expect(status == 0)
        #expect(!process.naturalSuccessfulExit)
    }
}
