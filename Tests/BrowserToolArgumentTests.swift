import ASTRACore
import Testing

@Suite("Browser Tool Arguments")
struct BrowserToolArgumentTests {
    @Test("Navigate prefers explicit url")
    func navigatePrefersExplicitURL() throws {
        let sanitized = try BrowserToolCommandParser.sanitizedArguments([
            "navigate",
            "--url",
            "https://docs.google.com/document/d/example/edit"
        ])
        var cursor = BrowserToolArgumentCursor(Array(sanitized.dropFirst()))

        #expect(BrowserToolCommandParser.navigateTarget(from: &cursor) == "https://docs.google.com/document/d/example/edit")
    }

    @Test("Navigate strips task global flag before url parsing")
    func navigateStripsTaskGlobalFlag() throws {
        let sanitized = try BrowserToolCommandParser.sanitizedArguments([
            "navigate",
            "--task",
            "F8C9FF92-5B74-4160-8DCA-359D59F7DFB8",
            "--url",
            "https://docs.google.com/document/d/example/edit"
        ])
        var cursor = BrowserToolArgumentCursor(Array(sanitized.dropFirst()))

        #expect(sanitized == [
            "navigate",
            "--url",
            "https://docs.google.com/document/d/example/edit"
        ])
        #expect(BrowserToolCommandParser.navigateTarget(from: &cursor) == "https://docs.google.com/document/d/example/edit")
    }

    @Test("Unknown flags fail fast")
    func unknownFlagsFailFast() throws {
        do {
            _ = try BrowserToolCommandParser.sanitizedArguments([
                "navigate",
                "--bogus",
                "https://docs.google.com/document/d/example/edit"
            ])
            Issue.record("Expected unknown flag error")
        } catch let error as BrowserToolArgumentError {
            #expect(error == .unknownFlag("--bogus"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Global task value does not leak into remaining text")
    func globalTaskValueDoesNotLeakIntoRemainingText() throws {
        let sanitized = try BrowserToolCommandParser.sanitizedArguments([
            "analyze",
            "--task",
            "F8C9FF92-5B74-4160-8DCA-359D59F7DFB8",
            "Alvaro1 t"
        ])
        var cursor = BrowserToolArgumentCursor(Array(sanitized.dropFirst()))

        #expect(cursor.remainingText() == "Alvaro1 t")
    }
}
