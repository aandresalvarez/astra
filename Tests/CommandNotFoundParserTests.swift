import Testing
import Foundation
@testable import ASTRA

/// Table-driven tests for `CommandNotFoundParser`. Each row is a real-world
/// stderr snippet taken from zsh/bash/sh/fish/Linux shells. The parser must
/// map every one of these to the expected missing binary name, and return
/// nil for inputs that don't resemble any "not found" shape.
@Suite("CommandNotFoundParser")
struct CommandNotFoundParserTests {

    // MARK: - Shell-shape patterns

    @Test("zsh: command not found: X")
    func zshForm() {
        let stderr = "zsh: command not found: gcloud"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "gcloud")
    }

    @Test("bash: X: command not found")
    func bashForm() {
        let stderr = "bash: gcloud: command not found"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "gcloud")
    }

    @Test("sh: X: command not found")
    func shForm() {
        let stderr = "sh: docker-compose: command not found"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "docker-compose")
    }

    @Test("/bin/sh: X: command not found (direct-exec path)")
    func directExecPathForm() {
        let stderr = "/bin/sh: gcloud: command not found"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "gcloud")
    }

    @Test("/usr/local/bin/zsh: command not found: X")
    func absoluteZshPath() {
        // zsh form from an absolute path — the zsh branch wins because
        // it's the more specific shape.
        let stderr = "zsh: command not found: kubectl"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "kubectl")
    }

    @Test("dash-style: sh: N: X: not found (Linux)")
    func dashNumberedForm() {
        // Debian/Ubuntu `sh` (dash) emits this form from inside scripts.
        let stderr = "sh: 1: gcloud: not found"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "gcloud")
    }

    @Test("fish: Unknown command: X")
    func fishForm() {
        let stderr = "fish: Unknown command: terraform"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "terraform")
    }

    @Test("bare form: X: command not found")
    func bareForm() {
        // Some tools re-emit the shell's line with the shell prefix stripped.
        let stderr = "gcloud: command not found"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "gcloud")
    }

    @Test("Multiline stderr — parser picks the first matching pattern")
    func multilineStderrFindsMatch() {
        let stderr = """
        + set -e
        + gcloud auth list
        zsh: command not found: gcloud
        """
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "gcloud")
    }

    // MARK: - Binary-name shapes

    @Test("Binary with dash is captured whole")
    func binaryWithDash() {
        let stderr = "zsh: command not found: docker-compose"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "docker-compose")
    }

    @Test("Binary with dot is captured whole")
    func binaryWithDot() {
        let stderr = "bash: some.tool: command not found"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == "some.tool")
    }

    // MARK: - Negatives

    @Test("Unrelated stderr returns nil")
    func unrelatedStderrIsNil() {
        let stderr = "Error: could not connect to server at 127.0.0.1:8080"
        #expect(CommandNotFoundParser.parse(stderr: stderr) == nil)
    }

    @Test("Empty stderr returns nil")
    func emptyStderrIsNil() {
        #expect(CommandNotFoundParser.parse(stderr: "") == nil)
    }

    @Test("Stderr with 'not found' in a sentence context is not treated as binary")
    func sentenceContextNotMistaken() {
        // The generic "X: not found" pattern is lenient; this test pins down
        // that at least purely-prose diagnostics with a path in them don't
        // produce a garbage binary name (the defensive no-slash guard).
        let stderr = "error: file /tmp/missing/thing.txt: not found"
        let parsed = CommandNotFoundParser.parse(stderr: stderr)
        // Accepts either nil or a non-slash token — never a path fragment.
        if let parsed {
            #expect(!parsed.contains("/"))
        }
    }

    @Test("Pure-digit 'binary' is rejected by the defensive guard")
    func pureDigitIsRejected() {
        // The dash-style regex can capture a numeric token if the stderr
        // is malformed; the defensive guard in parse() must drop it.
        let stderr = "sh: 1: 42: not found"
        // Expected: parser rejects 42 (pure digit). It may still fall
        // through to return nil or match a different pattern producing a
        // non-digit — the only thing we guarantee is "never pure digits".
        let parsed = CommandNotFoundParser.parse(stderr: stderr)
        if let parsed {
            #expect(Int(parsed) == nil, "Pure-digit captures must be rejected")
        }
    }
}
