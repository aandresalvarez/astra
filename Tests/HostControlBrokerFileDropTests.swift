import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// Covers the transport itself: the naming and permission rules both sides
/// depend on, and a real round trip through the listener using the same client
/// the helper binary runs. The client lives in ASTRACore rather than in the
/// tool so these are the same two halves that ship, not a re-implementation
/// that agrees with itself.
///
/// The client blocks its calling thread by design — it is a one-shot CLI, and
/// polling a directory is what it is for. That is wrong to do on a pooled
/// thread inside a test process: the listener's own watch and timer queues need
/// threads from the same pool, so a suite that blocks enough of them starves
/// the very broker it is waiting on. Every wait here runs either on a thread of
/// its own or on `Task.sleep`, and the suite is serialized so the round trips
/// do not stack up against the rest of the run.
@Suite("Host control broker file drop", .serialized)
struct HostControlBrokerFileDropTests {
    private func makeDirectoryPath() -> String {
        "/tmp/astra-drop-test-\(UUID().uuidString.lowercased())"
    }

    private func startedListener(
        token: String = HostControlBrokerFileDrop.newToken(),
        authorize: @escaping (Int32) -> Bool = { _ in true },
        handle: @escaping (String) -> String = { "echo:\($0)" }
    ) -> (listener: HostControlBrokerDropListener, directory: String, token: String)? {
        let listener = HostControlBrokerDropListener(
            token: token,
            authorize: authorize,
            handle: handle
        )
        guard let directory = listener.start(candidateDirectory: makeDirectoryPath()) else {
            return nil
        }
        return (listener, directory, token)
    }

    @Test("A drop directory must be absolute and free of traversal")
    func validatesDirectory() throws {
        #expect(try HostControlBrokerFileDrop.validatedDirectory("/tmp/astra-drop") == "/tmp/astra-drop")
        #expect(try HostControlBrokerFileDrop.validatedDirectory(" /tmp/astra-drop ") == "/tmp/astra-drop")
        #expect(throws: (any Error).self) {
            try HostControlBrokerFileDrop.validatedDirectory("tmp/astra-drop")
        }
        #expect(throws: (any Error).self) {
            try HostControlBrokerFileDrop.validatedDirectory("/tmp/../etc/astra-drop")
        }
        #expect(throws: (any Error).self) {
            try HostControlBrokerFileDrop.validatedDirectory("/tmp/astra\0drop")
        }
    }

    @Test("Only a published request file is picked up")
    func recognizesRequestFileNames() {
        let id = HostControlBrokerFileDrop.newRequestID()
        #expect(HostControlBrokerFileDrop.requestID(
            fromFileName: id + HostControlBrokerFileDrop.requestSuffix
        ) == id)
        // A staging file is a request that is still being written, and a
        // response is ASTRA's own output. Claiming either would answer a
        // request nobody finished asking.
        #expect(HostControlBrokerFileDrop.requestID(
            fromFileName: id + HostControlBrokerFileDrop.requestSuffix
                + HostControlBrokerFileDrop.stagingSuffix
        ) == nil)
        #expect(HostControlBrokerFileDrop.requestID(
            fromFileName: id + HostControlBrokerFileDrop.responseSuffix
        ) == nil)
        #expect(HostControlBrokerFileDrop.requestID(fromFileName: "notes.txt") == nil)
        #expect(HostControlBrokerFileDrop.requestID(
            fromFileName: "../escape" + HostControlBrokerFileDrop.requestSuffix
        ) == nil)
        #expect(HostControlBrokerFileDrop.requestID(
            fromFileName: HostControlBrokerFileDrop.requestSuffix
        ) == nil)
    }

    @Test("Token comparison rejects every kind of mismatch")
    func comparesTokens() {
        let token = HostControlBrokerFileDrop.newToken()
        #expect(HostControlBrokerFileDrop.tokensMatch(token, token))
        #expect(!HostControlBrokerFileDrop.tokensMatch(token, token + "0"))
        #expect(!HostControlBrokerFileDrop.tokensMatch(token, String(token.dropLast())))
        #expect(!HostControlBrokerFileDrop.tokensMatch("", ""))
        #expect(!HostControlBrokerFileDrop.tokensMatch(token, ""))
    }

    @Test("A fresh token is unguessable and never repeats")
    func drawsDistinctTokens() {
        let tokens = (0..<16).map { _ in HostControlBrokerFileDrop.newToken() }
        #expect(Set(tokens).count == tokens.count)
        #expect(tokens.allSatisfy { $0.count == 64 })
    }

    @Test("An atomic write publishes no staging file and stays owner-only")
    func writesAtomically() throws {
        let directory = makeDirectoryPath()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("payload.json")

        try HostControlBrokerFileDrop.writeAtomically(Data("first".utf8), to: url)
        try HostControlBrokerFileDrop.writeAtomically(Data("second".utf8), to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory)
        #expect(remaining == ["payload.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)
    }

    @Test("The drop directory is created owner-only and removed on invalidate")
    func ownsItsDirectory() throws {
        let session = try #require(startedListener())
        let mode = try FileManager.default.attributesOfItem(atPath: session.directory)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o700)

        session.listener.invalidate()
        #expect(!FileManager.default.fileExists(atPath: session.directory))
    }

    @Test("A listener with no token prepares nothing")
    func refusesToStartWithoutAToken() {
        let listener = HostControlBrokerDropListener(
            token: "",
            authorize: { _ in true },
            handle: { $0 }
        )
        let directory = makeDirectoryPath()
        #expect(listener.start(candidateDirectory: directory) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test("A request the helper writes comes back answered")
    func servesARoundTrip() async throws {
        let session = try #require(startedListener())
        defer { session.listener.invalidate() }

        let outcome = await exchange(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#,
            with: session
        )
        #expect(outcome == .reply(#"echo:{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#))
        // Both halves clean up after themselves: a directory that accumulates
        // answered requests is a directory that keeps this run's token on disk.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: session.directory)
        #expect(leftovers.isEmpty)
    }

    @Test("Successive requests are each answered")
    func servesSuccessiveRequests() async throws {
        let session = try #require(startedListener(handle: { "reply-to:\($0)" }))
        defer { session.listener.invalidate() }

        for index in 0..<3 {
            #expect(await exchange("call-\(index)", with: session) == .reply("reply-to:call-\(index)"))
        }
    }

    @Test("The reply carries the token, so a writer that cannot read cannot forge one")
    func repliesAreAuthenticated() async throws {
        let session = try #require(startedListener())
        defer { session.listener.invalidate() }

        let id = HostControlBrokerFileDrop.newRequestID()
        try write(
            HostControlBrokerFileDrop.Request(
                token: session.token,
                processID: ProcessInfo.processInfo.processIdentifier,
                line: "ping"
            ),
            asRequest: id,
            in: session.directory
        )

        let data = try #require(await waitForFile(
            at: HostControlBrokerFileDrop.responseURL(directory: session.directory, id: id)
        ))
        let response = try JSONDecoder().decode(HostControlBrokerFileDrop.Response.self, from: data)
        #expect(response.line == "echo:ping")
        #expect(response.token == session.token)
    }

    /// The other half of the same defence, and the half that runs on the
    /// helper: a reply is only a reply if it carries the run's token. Forged
    /// against a request that is genuinely in flight, because that is the only
    /// moment a forger could win — the client picks each request ID itself and
    /// never reads a response it did not ask for.
    @Test("A forged reply is ignored rather than returned to the agent")
    func ignoresAForgedReply() async throws {
        let directory = makeDirectoryPath()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        // No listener. The only thing that ever answers is the forger below.
        let token = HostControlBrokerFileDrop.newToken()
        async let outcome = exchangeOffThread(
            "ping",
            directory: directory,
            token: token,
            timeout: 8
        )

        let id = try #require(await waitForRequestID(in: directory))
        try write(
            HostControlBrokerFileDrop.Response(token: "not-the-token", line: "spoofed"),
            asResponse: id,
            in: directory
        )

        #expect(await outcome == .failed(.timedOut))
    }

    @Test("A request without this run's token is dropped without a reply")
    func ignoresAnUntokenedRequest() async throws {
        let session = try #require(startedListener())
        defer { session.listener.invalidate() }

        try await expectConsumedWithoutAReply(
            in: session.directory,
            writing: { id, directory in
                try self.write(
                    HostControlBrokerFileDrop.Request(
                        token: "wrong-token",
                        processID: ProcessInfo.processInfo.processIdentifier,
                        line: "ping"
                    ),
                    asRequest: id,
                    in: directory
                )
            }
        )
    }

    @Test("A request larger than the transport allows is ignored")
    func ignoresAnOversizedRequest() async throws {
        let session = try #require(startedListener())
        defer { session.listener.invalidate() }

        try await expectConsumedWithoutAReply(
            in: session.directory,
            writing: { id, directory in
                try HostControlBrokerFileDrop.writeAtomically(
                    Data(
                        repeating: 0x61,
                        count: HostControlBrokerFileDrop.maximumMessageBytes + 1
                    ),
                    to: HostControlBrokerFileDrop.requestURL(directory: directory, id: id)
                )
            }
        )
    }

    @Test("Malformed JSON is dropped rather than answered")
    func ignoresMalformedRequests() async throws {
        let session = try #require(startedListener())
        defer { session.listener.invalidate() }

        try await expectConsumedWithoutAReply(
            in: session.directory,
            writing: { id, directory in
                try HostControlBrokerFileDrop.writeAtomically(
                    Data("{ not json".utf8),
                    to: HostControlBrokerFileDrop.requestURL(directory: directory, id: id)
                )
            }
        )
    }

    @Test("A request from an unrecognized process is refused in terms the helper can read")
    func refusesAnUnauthorizedProcess() async throws {
        let session = try #require(startedListener(authorize: { _ in false }))
        defer { session.listener.invalidate() }

        let outcome = await exchange(
            #"{"jsonrpc":"2.0","id":11,"method":"tools/call"}"#,
            with: session
        )
        guard case .reply(let reply) = outcome else {
            Issue.record("Expected a JSON-RPC error, got \(outcome)")
            return
        }
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        )
        #expect(decoded["id"] as? Int == 11)
        let error = try #require(decoded["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("unrecognized process") == true)
    }

    /// The fallback is prepared for the runtimes that cannot reach the socket,
    /// and for no others. Cursor, OpenCode, and Antigravity use the same typed
    /// relay but run unsandboxed, so they keep the transport that can name its
    /// caller.
    @Test("Only a provider-sandboxed runtime is given the fallback")
    func limitsTheFallbackToSandboxedRuntimes() {
        #expect(HostControlBrokerSessionRegistry.providerSandboxedRuntimes.contains(.codexCLI))
        for runtime in [AgentRuntimeID.cursorCLI, .openCodeCLI, .antigravityCLI, .claudeCode] {
            #expect(!HostControlBrokerSessionRegistry.providerSandboxedRuntimes.contains(runtime))
        }
    }

    // MARK: - Waiting without holding a pooled thread

    private enum ExchangeOutcome: Equatable, Sendable {
        case reply(String)
        case failed(HostControlBrokerFileDropError)
        case unexpected(String)
    }

    private func exchange(
        _ line: String,
        with session: (listener: HostControlBrokerDropListener, directory: String, token: String),
        timeout: TimeInterval = 60
    ) async -> ExchangeOutcome {
        await exchangeOffThread(
            line,
            directory: session.directory,
            token: session.token,
            timeout: timeout
        )
    }

    /// A thread of its own, so the client's polling sleep never occupies one the
    /// listener needs.
    private func exchangeOffThread(
        _ line: String,
        directory: String,
        token: String,
        timeout: TimeInterval
    ) async -> ExchangeOutcome {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: .reply(
                        try HostControlBrokerFileDropClient.exchange(
                            line,
                            directory: directory,
                            token: token,
                            timeout: timeout
                        )
                    ))
                } catch let error as HostControlBrokerFileDropError {
                    continuation.resume(returning: .failed(error))
                } catch {
                    continuation.resume(returning: .unexpected("\(error)"))
                }
            }
            thread.name = "host-control-drop-client"
            thread.start()
        }
    }

    /// Writes a request the listener will claim, waits for it to disappear —
    /// which is the listener saying it read and consumed the file — and then
    /// checks that nothing was written back. Consumption is the signal rather
    /// than a fixed sleep, so a loaded machine makes this slower, not flaky.
    private func expectConsumedWithoutAReply(
        in directory: String,
        writing: (String, String) throws -> Void
    ) async throws {
        let id = HostControlBrokerFileDrop.newRequestID()
        try writing(id, directory)

        let requestURL = HostControlBrokerFileDrop.requestURL(directory: directory, id: id)
        #expect(await waitForRemoval(of: requestURL), "The listener never claimed the request")

        try? await Task.sleep(nanoseconds: 250_000_000)
        let responseURL = HostControlBrokerFileDrop.responseURL(directory: directory, id: id)
        #expect(!FileManager.default.fileExists(atPath: responseURL.path))
    }

    private func write(
        _ request: HostControlBrokerFileDrop.Request,
        asRequest id: String,
        in directory: String
    ) throws {
        try HostControlBrokerFileDrop.writeAtomically(
            try JSONEncoder().encode(request),
            to: HostControlBrokerFileDrop.requestURL(directory: directory, id: id)
        )
    }

    private func write(
        _ response: HostControlBrokerFileDrop.Response,
        asResponse id: String,
        in directory: String
    ) throws {
        try HostControlBrokerFileDrop.writeAtomically(
            try JSONEncoder().encode(response),
            to: HostControlBrokerFileDrop.responseURL(directory: directory, id: id)
        )
    }

    private func waitForFile(at url: URL, timeout: TimeInterval = 60) async -> Data? {
        await poll(timeout: timeout) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return data
        }
    }

    private func waitForRequestID(in directory: String, timeout: TimeInterval = 60) async -> String? {
        await poll(timeout: timeout) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.compactMap(HostControlBrokerFileDrop.requestID(fromFileName:)).first
        }
    }

    private func waitForRemoval(of url: URL, timeout: TimeInterval = 60) async -> Bool {
        await poll(timeout: timeout) {
            FileManager.default.fileExists(atPath: url.path) ? nil : true
        } ?? false
    }

    private func poll<Value>(
        timeout: TimeInterval,
        until produce: () -> Value?
    ) async -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = produce() { return value }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return produce()
    }
}
