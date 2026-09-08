import Foundation
import Testing
@testable import ASTRA

/// Some git commands are questions, not orders. `rev-parse` against a plain
/// directory exits 128 and that *is* the answer — but the process transport
/// logged every non-zero exit at ERROR, so a repository scan over configured
/// workspace folders filed one ERROR per non-repo folder while the caller,
/// three frames up, recorded the same outcome at `.debug` because it knew
/// better. `failureLogLevel` lets the caller's judgment reach the log line.
@Suite("Git probe failure level")
struct GitProbeFailureLevelTests {

    @Test("A probe's expected non-zero exit is not an error")
    func probeFailuresAreNotErrors() async throws {
        let entries = try await failureEntries(failureLogLevel: .debug)

        #expect(!entries.isEmpty, "The command must actually have failed for this to prove anything")
        #expect(entries.allSatisfy { $0.logLevel == .debug })
    }

    /// The default is unchanged: a command whose failure is genuinely a failure
    /// still reaches the channel people read.
    @Test("Commands that did not opt out still log at error")
    func defaultFailuresRemainErrors() async throws {
        let entries = try await failureEntries(failureLogLevel: nil)

        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.logLevel == .error })
    }

    /// Runs a git command guaranteed to exit non-zero and returns only the
    /// transport's own failure lines for *this* invocation.
    ///
    /// The marker rides in the arguments, which the transport echoes into the
    /// message, so the assertions never see a concurrently-running suite's git
    /// output — and this suite never has to reset the shared log buffer out
    /// from under one.
    private func failureEntries(failureLogLevel: LogLevel?) async throws -> [LogEntry] {
        // Short on purpose: `LogSanitizer` redacts any 40+ character run of
        // word characters, which a full UUID in this position would trip.
        let marker = "astra-probe-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(marker)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Not a repository, so this exits 128 whatever the ref is.
        let arguments = ["rev-parse", "--verify", "--quiet", marker]
        await #expect(throws: (any Error).self) {
            if let failureLogLevel {
                _ = try await GitService.shared.runGit(
                    at: directory.path,
                    arguments: arguments,
                    failureLogLevel: failureLogLevel
                )
            } else {
                _ = try await GitService.shared.runGit(at: directory.path, arguments: arguments)
            }
        }

        AppLogger.flushForTesting()
        return AppLogger.entries.filter {
            $0.category == "Git"
                && $0.message.contains("git command failed")
                && $0.message.contains(marker)
        }
    }
}
