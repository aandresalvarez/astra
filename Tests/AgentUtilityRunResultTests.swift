import Testing
import Foundation
@testable import ASTRA
@Suite("Utility run failure detail")
struct UtilityRunFailureDetailTests {
    @Test("stderr wins, stdout fallback, empty fallback")
    func failureDetailFallbacks() {
        #expect(AgentUtilityRunResult(exitCode: 1, output: "out", error: "real error").failureDetail == "real error")
        #expect(AgentUtilityRunResult(
            exitCode: 1,
            output: "API Error: Usage credits required for 1M context",
            error: "  \n"
        ).failureDetail == "API Error: Usage credits required for 1M context")
        #expect(AgentUtilityRunResult(exitCode: 1, output: "", error: "").failureDetail == "The provider produced no output.")
    }
}
