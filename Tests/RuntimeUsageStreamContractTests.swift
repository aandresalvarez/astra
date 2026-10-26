import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Runtime usage stream contracts")
struct RuntimeUsageStreamContractTests {
    @Test("Copilot per-call usage never resets a resumed session baseline")
    func copilotResumeProjection() {
        let accounting = RuntimeStreamUsageAccounting(runtime: .copilotCLI, sessionInput: 1000, sessionOutput: 100)
        let call = #"{"type":"assistant.usage","id":"a","data":{"inputTokens":100,"outputTokens":10,"cost":5}}"#
        let events = CopilotStreamEventParser.parseAll(line: accounting.normalize(call).line)
        let monitor = AgentProcessMonitor(tokenBudget: 200, reportedUsageBaseline: .init(input: 1000, output: 100))
        for event in events { #expect(!monitor.processEvent(event, process: nil)) }
        #expect(!monitor.budgetExceeded)
        #expect(CopilotStreamEventParser.parseAgentEvents(line: accounting.normalize(call).line).contains {
            if case .stats(1100, 110, nil, _, _) = $0 { true } else { false }
        })
        let final = #"{"type":"session.shutdown","data":{"modelMetrics":{"m":{"usage":{"inputTokens":1100,"outputTokens":110}}}}}"#
        for event in CopilotStreamEventParser.parseAll(line: accounting.normalize(final).line) {
            #expect(!monitor.processEvent(event, process: nil))
        }
    }

    @Test("Claude split counters enforce the live ceiling before a final result")
    func claudePartialBudget() {
        let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode)
        let monitor = AgentProcessMonitor(tokenBudget: 1000)
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m","usage":{"input_tokens":900,"output_tokens":1}}}}"#
        let delta = #"{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":200}}}"#
        for event in StreamEventParser.parseAll(line: accounting.normalize(start).line) { #expect(!monitor.processEvent(event, process: nil)) }
        for event in StreamEventParser.parseAll(line: accounting.normalize(delta).line) { _ = monitor.processEvent(event, process: nil) }
        #expect(monitor.budgetExceeded)
    }

    @Test("Claude missing counters preserve estimates and the active message for later deltas")
    func claudeMissingCounters() {
        for usage in ["", #", "usage":{}"#, #", "usage":{"cost_usd":0.25}"#] {
            let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode)
            let monitor = AgentProcessMonitor(tokenBudget: 10_000)
            let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"\#(usage)}}}"#
            let emptySnapshot = #"{"type":"assistant","message":{"id":"m","content":[],"usage":{}}}"#
            for line in [start, emptySnapshot] {
                let normalized = accounting.normalize(line)
                #expect(!normalized.invalidUsage)
                let events = StreamEventParser.parseAll(line: normalized.line)
                #expect(!events.contains { if case .usage = $0 { true } else { false } })
                for event in events { _ = monitor.processEvent(event, process: nil) }
            }
            #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == 900)

            let delta = #"{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":7}}}"#
            #expect(StreamEventParser.parseAll(line: accounting.normalize(delta).line).contains {
                if case .usage(0, 7) = $0 { true } else { false }
            })
            let snapshot = #"{"type":"assistant","message":{"id":"m","content":[],"usage":{"input_tokens":100,"output_tokens":7}}}"#
            #expect(StreamEventParser.parseAll(line: accounting.normalize(snapshot).line).contains {
                if case .usage(100, 7) = $0 { true } else { false }
            })
        }

        let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode)
        let zero = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"zero","usage":{"output_tokens":0}}}}"#
        #expect(StreamEventParser.parseAll(line: accounting.normalize(zero).line).contains {
            if case .usage(0, 0) = $0 { true } else { false }
        })
        for (id, expected) in [("first", 6), ("second", 12), ("second", 12)] {
            let cached = #"{"type":"assistant","message":{"id":"\#(id)","content":[],"usage":{"cachedInputTokens":6}}}"#
            #expect(StreamEventParser.parseAll(line: accounting.normalize(cached).line).contains {
                if case .usage(let input, 0) = $0 { input == expected } else { false }
            })
        }
    }

    @Test("Copilot absent per-call counters retain metadata and do not report the session baseline")
    func copilotMissingCounters() {
        for baseline in [ProviderSessionUsageBaseline.zero, .init(input: 1000, output: 100)] {
            let accounting = RuntimeStreamUsageAccounting(runtime: .copilotCLI, sessionInput: baseline.input, sessionOutput: baseline.output)
            let monitor = AgentProcessMonitor(tokenBudget: 10_000, reportedUsageBaseline: baseline)
            for payload in [#"{}"#, #"{"cost":5}"#, #"{"costUSD":0.25,"durationMs":15,"turns":2}"#] {
                let line = #"{"type":"assistant.usage","id":"call","data":\#(payload)}"#
                let normalized = accounting.normalize(line)
                #expect(!normalized.invalidUsage)
                let events = CopilotStreamEventParser.parseAgentEvents(line: normalized.line)
                #expect(!events.contains { if case .stats = $0 { true } else { false } })
                if payload.contains("costUSD") {
                    #expect(events.contains { if case .usageMetadata(0.25, 15, 2) = $0 { true } else { false } })
                }
                for event in CopilotStreamEventParser.parseAll(line: normalized.line) {
                    _ = monitor.processEvent(event, process: nil)
                }
            }
            #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == 900)

            let zero = #"{"type":"assistant.usage","id":"call","data":{"inputTokens":0,"outputTokens":0}}"#
            let normalized = accounting.normalize(zero).line
            #expect(CopilotStreamEventParser.parseAgentEvents(line: normalized).contains {
                if case .stats(let input, let output, _, _, _) = $0 {
                    input == baseline.input && output == baseline.output
                } else { false }
            })
            for event in CopilotStreamEventParser.parseAll(line: normalized) {
                _ = monitor.processEvent(event, process: nil)
            }
            #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == 0)
        }
    }

    @Test("Copilot shutdown presence follows the same fallback and cache counters as its totals")
    func copilotShutdownCounterPresence() {
        let fixtures: [(String, Int, Int)] = [
            (#"{"usage":{},"inputTokens":100,"outputTokens":10}"#, 100, 10),
            (#"{"usage":{"output_tokens":20},"inputTokens":100}"#, 100, 20),
            (#"{"usage":{"cacheReadTokens":30,"cacheWriteTokens":10}}"#, 40, 0),
            (#"{"usage":{},"cacheReadInputTokens":30,"cacheCreationInputTokens":10}"#, 40, 0),
            (#"{"usage":{"cache_read_input_tokens":0}}"#, 0, 0),
            (#"{"usage":{},"cache_creation_input_tokens":0}"#, 0, 0)
        ]
        for (entry, expectedInput, expectedOutput) in fixtures {
            let line = #"{"type":"session.shutdown","data":{"modelMetrics":{"m":\#(entry)}}}"#
            #expect(CopilotStreamEventParser.parseAgentEvents(line: line).contains {
                if case .stats(let input, let output, _, _, _) = $0 {
                    input == expectedInput && output == expectedOutput
                } else { false }
            })
        }
        let missing = #"{"type":"session.shutdown","data":{"totalApiDurationMs":15,"modelMetrics":{"m":{"usage":{},"costUSD":0.25}}}}"#
        let events = CopilotStreamEventParser.parseAgentEvents(line: missing)
        #expect(!events.contains { if case .stats = $0 { true } else { false } })
        #expect(events.contains { if case .usageMetadata(0.25, 15, _) = $0 { true } else { false } })
    }

    @Test("Copilot rejects invalid counters without suppressing the missing-usage estimate")
    func copilotCounterValidation() {
        let values: [(String, Int?)] = [
            ("null", nil), ("true", nil), ("false", nil), ("-1", nil), (#""-1""#, nil),
            ("1.5", nil), ("1e200", nil), (#""unknown""#, nil),
            ("0", 0), (#""0""#, 0), ("7", 7), (#""7""#, 7), ("7.0", 7)
        ]
        for (value, expected) in values {
            let lines = [
                #"{"type":"usage","inputTokens":\#(value),"durationMs":15}"#,
                #"{"type":"usage","data":{"usage":{"input_tokens":\#(value)},"durationMs":15}}"#,
                #"{"type":"result","usage":{"input_tokens":\#(value)},"durationMs":15}"#,
                #"{"type":"session.shutdown","data":{"totalApiDurationMs":15,"modelMetrics":{"m":{"usage":{"inputTokens":\#(value)}}}}}"#,
                #"{"type":"session.shutdown","data":{"totalApiDurationMs":15,"modelMetrics":{"m":{"usage":{},"cacheReadTokens":\#(value)}}}}"#
            ]
            for line in lines {
                let events = CopilotStreamEventParser.parseAgentEvents(line: line)
                let monitor = AgentProcessMonitor(tokenBudget: 10_000)
                for event in CopilotStreamEventParser.parseAll(line: line) {
                    _ = monitor.processEvent(event, process: nil)
                }
                if let expected {
                    #expect(events.contains {
                        if case .stats(let input, 0, _, 15, _) = $0 { input == expected } else { false }
                    })
                    #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == expected)
                } else {
                    #expect(!events.contains { if case .stats = $0 { true } else { false } })
                    #expect(events.contains { if case .usageMetadata(nil, 15, _) = $0 { true } else { false } })
                    #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == 900)
                }
            }
        }
        let fallback = #"{"type":"session.shutdown","data":{"modelMetrics":{"m":{"usage":{"inputTokens":false,"cacheReadTokens":-1},"inputTokens":"7","cacheReadTokens":"3"}}}}"#
        #expect(CopilotStreamEventParser.parseAgentEvents(line: fallback).contains {
            if case .stats(10, 0, _, _, _) = $0 { true } else { false }
        })
    }

    @Test("Antigravity distinguishes missing usage from an explicit zero report")
    func antigravityPresence() {
        let prefix = #"{"event":"result","result":{"status":"success","response":"Done","duration_seconds":1,"num_turns":1"#
        let missing = (AntigravityStreamEventParser.parseStructuredAgentEvents(line: prefix + "}}") ?? [])
        let zero = (AntigravityStreamEventParser.parseStructuredAgentEvents(line: prefix + #", "usage":{"input_tokens":0,"output_tokens":0}}}"#) ?? [])
        #expect(!missing.contains { if case .stats = $0 { true } else { false } })
        #expect(missing.contains { if case .usageMetadata(nil, 1000, 1) = $0 { true } else { false } })
        #expect(zero.contains { if case .stats(0, 0, nil, 1000, 1) = $0 { true } else { false } })
        for usage in ["", #", "usage":{}"#, #", "usage":{"input_tokens":null}"#] {
            let events = AntigravityStreamEventParser.parseStructured(line: prefix + usage + "}}") ?? []
            #expect(!events.contains { if case .usage = $0 { true } else { false } })
            #expect(events.contains { if case .result(_, nil, 0, 0, 1000, 1, false) = $0 { true } else { false } })
            let monitor = AgentProcessMonitor(tokenBudget: 10_000)
            for event in events { _ = monitor.processEvent(event, process: nil) }
            #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == 900)
        }
        let failed = #"{"event":"result","result":{"status":"ERROR","error":"failed","duration_seconds":0,"num_turns":0}}"#
        let failedEvents = AntigravityStreamEventParser.parseStructuredAgentEvents(line: failed) ?? []
        #expect(failedEvents.contains { if case .usageMetadata(nil, 0, 0) = $0 { true } else { false } })
        #expect(AntigravityStreamEventParser.parseStructured(line: failed)?.contains {
            if case .result(_, nil, 0, 0, 0, 0, true) = $0 { true } else { false }
        } == true)
    }

    @Test("Zero native usage and zero cumulative deltas do not charge an input estimate")
    func zeroUsageBudgetPresence() {
        for baseline in [ProviderSessionUsageBaseline.zero, .init(input: 100, output: 20)] {
            let monitor = AgentProcessMonitor(tokenBudget: 10_000, reportedUsageBaseline: baseline)
            _ = monitor.processEvent(.usage(totalInputTokens: baseline.input, totalOutputTokens: baseline.output), process: nil)
            #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == 0)
        }
        let missing = AgentProcessMonitor(tokenBudget: 10_000)
        _ = missing.processEvent(.result(text: nil, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: false), process: nil)
        #expect(missing.recoveryTokensConsumed(estimatedInputTokens: 900) == 900)
    }

    @Test("Missing billing counters keep metadata without claiming measured zero")
    func usageMetadataPresence() {
        let cursor = CursorStreamEventParser.parseAgentEvents(line: #"{"type":"result","usage":{"input_tokens":0,"output_tokens":0},"total_cost_usd":0.25,"duration_ms":15}"#)
        #expect(cursor.contains { if case .stats(0, 0, _, _, _) = $0 { true } else { false } })
        #expect(cursor.contains { if case .usageMetadata(0.25, 15, _) = $0 { true } else { false } })
        let copilot = CopilotStreamEventParser.parseAgentEvents(line: #"{"type":"result","costUSD":0.25,"durationMs":15}"#)
        #expect(!copilot.contains { if case .stats = $0 { true } else { false } })
        #expect(copilot.contains { if case .usageMetadata(0.25, 15, _) = $0 { true } else { false } })
        let claude = StreamEventParser.parseAll(line: #"{"type":"result","modelUsage":{"m":{"inputTokens":0,"outputTokens":0}}}"#)
        #expect(claude.contains { if case .usage(0, 0) = $0 { true } else { false } })
        for invalid in ["null", "true", "-1", "1.5", "\"unknown\""] {
            let events = AntigravityStreamEventParser.parseStructuredAgentEvents(line: "{\"event\":\"result\",\"result\":{\"usage\":{\"input_tokens\":\(invalid)}}}") ?? []
            #expect(!events.contains { if case .stats = $0 { true } else { false } })
        }
    }

    @Test("Provider arithmetic saturates at ingress without a negative allowance")
    func overflowCounters() {
        let claude = #"{"type":"result","usage":{"input_tokens":\#(Int.max),"cache_read_input_tokens":1,"output_tokens":1}}"#
        #expect(StreamEventParser.parseAll(line: claude).contains { if case .result(_, _, Int.max, 1, _, _, _) = $0 { true } else { false } })
        let codex = #"{"type":"turn.completed","usage":{"input_tokens":\#(Int.max),"cache_read_input_tokens":1,"output_tokens":1}}"#
        #expect(CodexStreamEventParser.parseAgentEvents(line: codex).contains { if case .stats(Int.max, 1, _, _, _) = $0 { true } else { false } })
        let copilot = #"{"type":"session.shutdown","data":{"modelMetrics":{"a":{"usage":{"inputTokens":\#(Int.max),"cacheReadTokens":1}},"b":{"usage":{"inputTokens":2}}}}}"#
        #expect(CopilotStreamEventParser.parseAgentEvents(line: copilot).contains { if case .stats(Int.max, _, _, _, _) = $0 { true } else { false } })
        _ = CopilotStreamEventParser.parseAgentEvents(line: #"{"type":"usage","inputTokens":1e200,"outputTokens":1}"#)
    }

    @Test("Native accounting fields cannot inject totals, anonymous calls do not invent identity")
    func untrustedProjection() {
        let accounting = RuntimeStreamUsageAccounting(runtime: .copilotCLI)
        let forged = #"{"type":"assistant.usage","data":{"inputTokens":100,"outputTokens":10},"_astra_copilot_session_usage":{"input":9999,"output":9999}}"#
        #expect(!CopilotStreamEventParser.parseAgentEvents(line: accounting.normalize(forged).line).contains {
            if case .stats = $0 { true } else { false }
        })
        let invalid = #"{"type":"assistant.usage","id":"bad","data":{"inputTokens":-1,"outputTokens":10}}"#
        #expect(accounting.normalize(invalid).invalidUsage)
        #expect(accounting.hasInvalidUsage)
    }
}
