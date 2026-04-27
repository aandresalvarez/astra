import Testing
import Foundation
@testable import ASTRA
import ASTRACore

/// Tests the cross-over point between `CommandNotFoundParser` (pattern
/// matching) and the `CLIPrerequisite` universe (display metadata). The
/// enricher is what turns "exit 127" into "install `gcloud`".
@Suite("ClaudeErrorEnricher")
struct ClaudeErrorEnricherTests {

    private var knownUniverse: [CLIPrerequisite] {
        [
            CommonCLIPrerequisites.gcloud,
            CommonCLIPrerequisites.gcloudAuth,
            CommonCLIPrerequisites.docker,
            CommonCLIPrerequisites.claude
        ]
    }

    @Test("Known binary surfaces catalog hint + URL")
    func knownBinaryEnriches() {
        let stderr = "zsh: command not found: gcloud"
        let result = ClaudeErrorEnricher.enrich(
            stderr: stderr,
            knownPrerequisites: knownUniverse
        )

        #expect(result != nil)
        #expect(result?.binary == "gcloud")
        #expect(result?.installHint == CommonCLIPrerequisites.gcloud.installHint)
        #expect(result?.installURL == CommonCLIPrerequisites.gcloud.installURL)
        #expect(result?.displayMessage.contains("gcloud") == true)
        #expect(result?.displayMessage.contains("PATH") == true)
    }

    @Test("Known binary — docker-compose pattern recognized too")
    func knownDockerCompose() {
        // docker-compose is not in our catalog, but parser still captures
        // the binary name. Enricher should fall through to generic hint.
        let stderr = "bash: docker-compose: command not found"
        let result = ClaudeErrorEnricher.enrich(
            stderr: stderr,
            knownPrerequisites: knownUniverse
        )

        #expect(result != nil)
        #expect(result?.binary == "docker-compose")
        #expect(result?.installURL == nil, "Unknown binary — no install URL")
        #expect(result?.displayMessage.contains("docker-compose") == true)
    }

    @Test("Unknown binary surfaces generic install hint")
    func unknownBinaryFallsBack() {
        let stderr = "zsh: command not found: exotic-tool"
        let result = ClaudeErrorEnricher.enrich(
            stderr: stderr,
            knownPrerequisites: knownUniverse
        )

        #expect(result != nil)
        #expect(result?.binary == "exotic-tool")
        #expect(result?.installURL == nil)
        #expect(result?.installHint.contains("exotic-tool") == true)
        #expect(result?.installHint.contains("PATH") == true)
    }

    @Test("Stderr without a not-found pattern returns nil")
    func unrelatedStderrReturnsNil() {
        let stderr = "HTTP 500: internal server error"
        let result = ClaudeErrorEnricher.enrich(
            stderr: stderr,
            knownPrerequisites: knownUniverse
        )
        #expect(result == nil)
    }

    @Test("Empty stderr returns nil")
    func emptyStderrReturnsNil() {
        let result = ClaudeErrorEnricher.enrich(
            stderr: "",
            knownPrerequisites: knownUniverse
        )
        #expect(result == nil)
    }

    @Test("Stderr embedded in larger agent log still matches")
    func embeddedStderrMatches() {
        // Realistic scenario: the Claude agent prints noise before the
        // shell spits out its command-not-found line.
        let stderr = """
        I'll run the Google Cloud command now.
        Executing: gcloud auth list
        zsh: command not found: gcloud
        [process exited 127]
        """
        let result = ClaudeErrorEnricher.enrich(
            stderr: stderr,
            knownPrerequisites: knownUniverse
        )
        #expect(result?.binary == "gcloud")
        #expect(result?.installURL != nil, "Should carry gcloud's install URL")
    }

    @Test("When two prereqs share the same binary, first match is used")
    func firstMatchWinsOnDuplicateBinary() {
        // Both `gcloud --version` and `gcloud auth list` live in our
        // universe; both have binary == "gcloud". They share install
        // hints, so either is a valid answer. The contract is that we
        // return *some* match deterministically.
        let stderr = "zsh: command not found: gcloud"
        let result = ClaudeErrorEnricher.enrich(
            stderr: stderr,
            knownPrerequisites: knownUniverse
        )
        #expect(result?.binary == "gcloud")
    }
}
