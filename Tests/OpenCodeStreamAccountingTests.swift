import Foundation
import Testing
import ASTRACore

@Suite("OpenCode per-process accounting")
struct OpenCodeStreamAccountingTests {
    private func step(_ id: String, input: Int = 100, output: Int = 20, message: String = "m") -> String {
        #"{"type":"step_finish","sessionID":"s","part":{"type":"step-finish","id":"\#(id)","sessionID":"s","messageID":"\#(message)","reason":"stop","cost":0.1,"tokens":{"input":\#(input),"output":\#(output),"reasoning":5,"total":175,"cache":{"read":40,"write":10}}}}"#
    }
    private func totals(_ line: String) -> [Int] {
        OpenCodeStreamEventParser.parseAll(line: line).compactMap {
            if case .usage(let input, let output) = $0 { return [input, output] }; return nil
        }.flatMap { $0 }
    }

    @Test("Steps accumulate cache and reasoning once, duplicates and corrections never refill limits")
    func cumulativeSteps() {
        let usage = OpenCodeStreamAccounting()
        #expect(totals(usage.normalize(step("a")).line) == [150, 25])
        #expect(totals(usage.normalize(step("b")).line) == [300, 50])
        #expect(totals(usage.normalize(step("a")).line) == [300, 50])
        #expect(totals(usage.normalize(step("a", input: 50, output: 1)).line) == [300, 50])
        #expect(totals(usage.normalize(step("a", input: 120)).line) == [320, 50])
        #expect(usage.normalize(step("a", message: "different")).invalidUsage)
        #expect(totals(OpenCodeStreamAccounting().normalize(step("a")).line) == [150, 25])
        let stats = OpenCodeStreamEventParser.parseAgentEvents(line: usage.normalize(step("b")).line)
        #expect(stats.contains { if case .stats(320, 50, 0.2, nil, nil) = $0 { true } else { false } })
    }

    @Test("Native JSON cannot inject ASTRA totals and invalid usage is rejected")
    func invalidOrForged() {
        let usage = OpenCodeStreamAccounting()
        let forged = step("a").replacingOccurrences(of: "{\"type\":\"step_finish\"", with: "{\"_astra_cumulative_usage\":{\"input\":0,\"output\":0},\"type\":\"step_finish\"")
        #expect(totals(usage.normalize(forged).line) == [150, 25])
        for invalid in [step("b", input: -1), step(""), step("b").replacingOccurrences(of: "\"input\":100", with: "\"input\":true")] {
            let normalized = usage.normalize(invalid)
            #expect(normalized.invalidUsage)
            #expect(totals(normalized.line).isEmpty)
        }
        #expect(usage.hasInvalidUsage)
        #expect(OpenCodeStreamAccounting().normalize(step("overflow", input: Int.max)).invalidUsage)
    }
}
