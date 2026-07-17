import Darwin
import Foundation
import Testing
@testable import RunSupervisorSupport

@Suite("Run supervisor Unix control socket", .serialized)
struct RunSupervisorUnixSocketTests {
    @Test("socket authenticates a request and rejects nonce replay")
    func authenticatedRequest() throws {
        let fixture = try makeFixture()
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator
        )
        try server.start { _ in .init(accepted: true, lastSequence: 0) }
        defer { server.stop() }
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: fixture.payload.manifest.executionID,
            action: .init(kind: .status),
            capability: fixture.payload.capability
        )
        let client = DarwinRunSupervisorControlClient()
        #expect(try client.send(request, directory: fixture.directory).accepted)
        let replay = try client.send(request, directory: fixture.directory)
        #expect(!replay.accepted)
        #expect(replay.errorCode == "unauthenticated")
    }

    @Test("start refuses symlink and regular-file socket substitutions")
    func startRefusesSubstitutions() throws {
        let fixture = try makeFixture()
        let victim = URL(fileURLWithPath: fixture.directory.path).appendingPathComponent("victim")
        try Data("safe".utf8).write(to: victim)
        let socket = URL(fileURLWithPath: fixture.directory.path).appendingPathComponent("control.sock")
        #expect(symlink(victim.path, socket.path) == 0)
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator
        )
        #expect(throws: RunSupervisorError.unsafeFilesystemEntry("control.sock")) {
            try server.start { _ in .init(accepted: true, lastSequence: 0) }
        }
        #expect(try String(contentsOf: victim) == "safe")
        #expect(throws: RunSupervisorError.unsafeFilesystemEntry("control.sock")) {
            try DarwinRunSupervisorFileSystem().removeControlSocket(in: fixture.directory)
        }
    }

    @Test("stop never unlinks a replacement path with a different inode")
    func stopPreservesReplacement() throws {
        let fixture = try makeFixture()
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: fixture.payload.manifest.executionID,
            capability: fixture.payload.capability
        )
        let server = try DarwinRunSupervisorSocketServer(
            directory: fixture.directory,
            authenticator: authenticator
        )
        try server.start { _ in .init(accepted: true, lastSequence: 0) }
        let path = URL(fileURLWithPath: fixture.directory.path).appendingPathComponent("control.sock")
        #expect(unlink(path.path) == 0)
        try Data("replacement".utf8).write(to: path)
        server.stop()
        #expect(try String(contentsOf: path) == "replacement")
    }

    private func makeFixture() throws -> (
        root: RunSupervisorTrustedRoot,
        directory: RunSupervisorRunDirectory,
        payload: RunSupervisorBootstrapPayload
    ) {
        let url = try RunSupervisorTestSupport.temporaryDirectory("socket")
        let root = try RunSupervisorTrustedRoot(path: url.path)
        let payload = try RunSupervisorTestSupport.payload(identitySeed: UInt8.random(in: 30...100))
        let directory = try root.acquireExecutionDirectory(payload.manifest.executionID).directory
        return (root, directory, payload)
    }
}
