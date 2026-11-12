import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The cause list is for the launch log. These tests pin that it names the
/// input that left cleanup unproven, prints no values, and stays empty exactly
/// when `toolsStopped` is true.
@Suite("Runtime provider cleanup uncertainty causes")
struct RuntimeProviderCleanupCauseTests {
    typealias Copilot = RuntimeCopilotFrameMetadataTests

    @Test("A stream that proves its tools stopped has no cause", arguments: Copilot.toolFreeStreams)
    func cleanStreamHasNoCause(name: String) throws {
        let evidence = try Copilot.evidence(Copilot.stream(name))
        #expect(evidence.toolsStopped && evidence.cleanupUncertainty.isEmpty)
    }

    @Test("An unrecognized field is named by frame type, field path and value kind")
    func unclassifiedFrameNamesTheField() throws {
        var frames = try Copilot.stream(Copilot.hostControlStream)
        let index = try #require(frames.firstIndex { $0["type"] as? String == "session.mcp_servers_loaded" })
        frames[index] = try #require(Copilot.replacing(frames[index],
            at: ["data", "servers", "0", "serverMetadata", "instructions"], with: 0) as? [String: Any])
        let evidence = try Copilot.evidence(frames)
        #expect(!evidence.toolsStopped)
        #expect(evidence.cleanupUncertainty == ["unclassified:session.mcp_servers_loaded[servers{displayName:absent|s,"
            + "name:s,serverMetadata{instructions:n|s},source:absent|s,status:s}]"])
    }

    @Test("A tool request is named without its arguments' values")
    func toolRequestPrintsNoValues() throws {
        var frames = try Copilot.stream(Copilot.toolFreeStreams[0])
        let index = try #require(frames.firstIndex { $0["type"] as? String == "assistant.message" })
        frames[index] = try #require(Copilot.replacing(frames[index], at: ["data", "toolRequests"],
            with: [["toolCallId": "call-secret", "name": "bash", "arguments": ["command": "cat /Users/someone/private.txt"]]]) as? [String: Any])
        let causes = try Copilot.evidence(frames).cleanupUncertainty
        #expect(causes.contains { $0.hasPrefix("unclassified:assistant.message[") }, "\(causes)")
        #expect(causes.contains { $0.contains("toolRequests{arguments{command:s},name:s,toolCallId:s}") }, "\(causes)")
        // Every string value in the fixture is `fixture`; none may be printed.
        #expect(!causes.contains { $0.contains("fixture") || $0.contains("secret") || $0.contains("/Users") || $0.contains("bash") })
    }

    @Test("Keys and types that are not identifiers are masked, and nesting is bounded")
    func dataKeyedMapsAreMasked() throws {
        let frame: [String: Any] = ["type": "fixture.unknown work", "data": [
            "/Users/someone/private.txt": 1, "ok_key": "value", "a": ["b": ["c": ["d": true]]],
            String(repeating: "k", count: 49): NSNull()]]
        let cause = RuntimeExecutionUncertaintyCause.frame("unclassified", frame)
        #expect(cause == "unclassified:?[?:n,a{b{c{}}},?:null,ok_key:s]")
        let wide = Dictionary(uniqueKeysWithValues: (10..<40).map { ("k\($0)", 1) })
        let shape = RuntimeExecutionUncertaintyCause.frame("unclassified", ["type": "fixture.wide", "data": wide])
        #expect(shape.hasPrefix("unclassified:fixture.wide[k10:n,") && shape.hasSuffix(",k33:n,+6]"), "\(shape)")
        #expect(RuntimeExecutionUncertaintyCause.frame("unclassified", ["data": 3]) == "unclassified:untyped")
    }

    @Test("Stream-level causes are named, and the list is bounded")
    func streamLevelCauses() throws {
        let clean = try Copilot.stream(Copilot.toolFreeStreams[0])

        let noResult = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        for frame in clean.dropLast() { try RuntimeManagedSSHHelperEvidenceTests.observe(frame, runtime: .copilotCLI, in: noResult) }
        noResult.processExited(naturally: true, stdoutEOF: true)
        #expect(noResult.cleanupUncertainty == ["no_terminal_frame"])

        let noEOF = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        for frame in clean { try RuntimeManagedSSHHelperEvidenceTests.observe(frame, runtime: .copilotCLI, in: noEOF) }
        noEOF.processExited(naturally: false, stdoutEOF: false)
        #expect(noEOF.cleanupUncertainty == ["no_stdout_eof", "no_terminal_frame"])

        let broker = RuntimeManagedSSHBrokerEvidence()
        broker.beginCommand()
        let helper = RuntimeExecutionProcessEvidence(runtime: .copilotCLI, managedSSHBroker: broker)
        for frame in clean { try RuntimeManagedSSHHelperEvidenceTests.observe(frame, runtime: .copilotCLI, in: helper) }
        helper.processExited(naturally: true, stdoutEOF: true)
        #expect(!helper.toolsStopped && helper.cleanupUncertainty == ["managed_helper_broker_activity"])

        let lines = RuntimeExecutionProcessEvidence(runtime: .copilotCLI)
        lines.observeFrame("not json", parsesJSONLines: true, events: [])
        lines.observeFrame("plain text", parsesJSONLines: false, events: [.text(text: "plain text")])
        lines.observeFrame(#"{"type":"fixture.silent","data":{"count":1}}"#, parsesJSONLines: true, events: [])
        lines.observe(.unknown(type: "native_session_ownership_unverified"))
        #expect(lines.cleanupUncertainty == ["line_not_json", "plain_text_stream", "no_parsed_events:fixture.silent[count:n]",
                                             "owned_event", "no_terminal_frame"])

        var many = clean
        for index in 0..<10 { many.insert(["type": "fixture.unknown_\(index)", "data": [String: Any]()], at: many.count - 1) }
        let bounded = try Copilot.evidence(many)
        #expect(bounded.cleanupUncertainty.count == RuntimeExecutionUncertaintyCause.limit)
        #expect(bounded.cleanupUncertainty.first?.hasSuffix(":fixture.unknown_0") == true, "\(bounded.cleanupUncertainty)")
    }
}
