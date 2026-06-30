import Foundation
import MailToolSupport
import Testing

@Suite("Stanford Apple Mail tool")
struct StanfordAppleMailToolTests {
    @Test("missing message errors render attacker input as an AppleScript string literal")
    func missingMessageErrorRendersAttackerInputAsAppleScriptLiteral() {
        let messageID = #"missing" & do shell script "printf ASTRA_INJECTION_PROOF" & ""#

        let statement = AppleScriptSource.errorStatement(
            "No Apple Mail message matches message id \(messageID)."
        )

        #expect(statement == #"error "No Apple Mail message matches message id missing\" & do shell script \"printf ASTRA_INJECTION_PROOF\" & \".""#)
        #expect(!statement.contains(#"missing" & do shell script"#))
    }

    @Test("get command source does not interpolate the raw message id in the missing-message branch")
    func getCommandSourceDoesNotInterpolateRawMessageID() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Tools/StanfordAppleMailTool/main.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains(#"error "No Apple Mail message matches message id \(messageID).""#))
        #expect(source.contains("AppleScriptSource.errorStatement"))
    }
}
