import ASTRACore
import ASTRARunLedger
import CryptoKit
import Darwin
import Dispatch
import Foundation
import RunBrokerKit
import RunSupervisorSupport
import Testing
@testable import RunBrokerService

@Suite("RunBroker typed projection outbox hardening", .serialized)
struct RunBrokerProjectionOutboxHardeningTests {
    @Test("save-before-ACK handshake accepts exact and one-ahead cursors and rejects drift")
    func saveBeforeAcknowledgementHandshake() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        let outbox = RunBrokerProjectionOutbox(ledger: fixture.ledger)
        let first = try #require(try outbox.next())

        let exact = try outbox.handshake(.init(
            acknowledgedThrough: 0,
            acknowledgedMessageID: nil
        ))
        #expect(exact.brokerAcknowledgedThrough == 0)
        #expect(exact.next == first)

        let savedBeforeAck = try outbox.handshake(.init(
            acknowledgedThrough: first.sequence,
            acknowledgedMessageID: first.messageID
        ))
        #expect(savedBeforeAck.brokerAcknowledgedThrough == 0)
        #expect(savedBeforeAck.next == first)

        #expect(throws: RunBrokerApplicationEndpointError.projectionAcknowledgementConflict) {
            _ = try outbox.handshake(.init(
                acknowledgedThrough: first.sequence,
                acknowledgedMessageID: brokerUUID(250)
            ))
        }

        _ = try outbox.acknowledge(.init(
            sequence: first.sequence,
            messageID: first.messageID
        ))
        #expect(throws: RunBrokerApplicationEndpointError.projectionAcknowledgementConflict) {
            _ = try outbox.handshake(.init(
                acknowledgedThrough: 0,
                acknowledgedMessageID: nil
            ))
        }
        let afterAck = try outbox.handshake(.init(
            acknowledgedThrough: first.sequence,
            acknowledgedMessageID: first.messageID
        ))
        #expect(afterAck.brokerAcknowledgedThrough == first.sequence)
        #expect(afterAck.next?.sequence == first.sequence + 1)
    }

    @Test("handshake remains one WAL snapshot while another connection ACKs and appends")
    func handshakeIsConsistentAcrossConcurrentConnections() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        let first = try #require(try RunBrokerProjectionOutbox(ledger: fixture.ledger).next())
        let originalHead = try #require(try fixture.ledger.outboxHead())

        let concurrentLedger = try RunLedger(configuration: .init(
            ledgerDirectoryURL: fixture.root.appendingPathComponent("ledger", isDirectory: true),
            installationID: fixture.manifest.installationID,
            expectedStoreID: fixture.ledger.identity.storeID
        ))
        defer { try? concurrentLedger.close() }

        let snapshotEstablished = DispatchSemaphore(value: 0)
        let resumeSnapshot = DispatchSemaphore(value: 0)
        let handshakeFinished = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let handshakeResult = ProjectionConcurrentResultBox<RunBrokerApplicationProjectionHandshake>()
        let writerResult = ProjectionConcurrentResultBox<Void>()
        let handshakeOutbox = RunBrokerProjectionOutbox(
            ledger: fixture.ledger,
            afterSnapshotAcknowledgementRead: {
                snapshotEstablished.signal()
                resumeSnapshot.wait()
            }
        )
        let concurrentOutbox = RunBrokerProjectionOutbox(ledger: concurrentLedger)
        let executionID = fixture.manifest.executionID
        let authority = fixture.manifest.authority

        DispatchQueue.global(qos: .userInitiated).async {
            handshakeResult.capture {
                try handshakeOutbox.handshake(.init(
                    acknowledgedThrough: 0,
                    acknowledgedMessageID: nil
                ))
            }
            handshakeFinished.signal()
        }
        guard snapshotEstablished.wait(timeout: .now() + .seconds(2)) == .success else {
            resumeSnapshot.signal()
            Issue.record("Handshake did not establish its read snapshot")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            writerResult.capture {
                _ = try concurrentOutbox.acknowledge(.init(
                    sequence: first.sequence,
                    messageID: first.messageID
                ))
                _ = try concurrentLedger.append(.init(
                    eventID: .init(rawValue: brokerUUID(251)),
                    occurredAt: brokerTestDate.addingTimeInterval(100),
                    event: .executionControlTransitioned(
                        executionID: executionID,
                        authority: authority,
                        transition: .requestCancellation(.immediate),
                        backendCapabilities: [.observe, .cancel]
                    )
                ))
            }
            writerFinished.signal()
        }

        let writerCompletedWithoutWaiting = writerFinished.wait(
            timeout: .now() + .seconds(2)
        ) == .success
        resumeSnapshot.signal()
        #expect(writerCompletedWithoutWaiting)
        guard handshakeFinished.wait(timeout: .now() + .seconds(2)) == .success else {
            Issue.record("Handshake did not finish after its snapshot resumed")
            return
        }

        try writerResult.get()
        let handshake = try handshakeResult.get()
        try handshake.validate()
        #expect(handshake.brokerAcknowledgedThrough == 0)
        #expect(handshake.durableHeadSequence == originalHead.sequence)
        #expect(handshake.durableHeadMessageID == originalHead.messageID.rawValue)
        #expect(handshake.next == first)
        #expect(try fixture.ledger.outboxAcknowledgedThrough() == first.sequence)
        #expect(try fixture.ledger.outboxHead()?.sequence == originalHead.sequence + 1)
    }

    @Test("backlog replays exact immutable messages in bounded sequence order after restart")
    func exactBacklogReplay() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
            fixture.event(3, .standardOutput, output: Data("one".utf8)),
            fixture.event(4, .standardOutput, output: Data("two\n".utf8)),
        ]
        _ = try fixture.orchestrator().start(fixture.request())

        let firstBroker = RunBrokerProjectionOutbox(ledger: fixture.ledger)
        let first = try #require(try firstBroker.next())
        let restarted = RunBrokerProjectionOutbox(ledger: fixture.ledger)
        #expect(try restarted.next() == first)

        var delivered: [RunBrokerApplicationProjectionMessage] = []
        while let message = try restarted.next() {
            try message.validate()
            delivered.append(message)
            _ = try restarted.acknowledge(.init(
                sequence: message.sequence,
                messageID: message.messageID
            ))
        }
        #expect(!delivered.isEmpty)
        #expect(delivered.map(\.sequence) == Array(1...Int64(delivered.count)))
        #expect(Set(delivered.map(\.messageID)).count == delivered.count)
        #expect(try restarted.next() == nil)
    }

    @Test("stream continuation spans chunks, resets on newline, and caps oversized fragments")
    func boundedStreamContinuation() throws {
        let fixture = try BrokerFixture(
            maximumOutputEventBytes: 32_768,
            maximumPersistedOutputBytes: 1_048_576
        )
        let chunk = Data(repeating: 0x61, count: 32_768)
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
            fixture.event(3, .standardOutput, output: chunk),
            fixture.event(4, .standardOutput, output: chunk),
            fixture.event(5, .standardOutput, output: chunk),
            fixture.event(6, .standardOutput, output: chunk),
            fixture.event(7, .standardOutput, output: chunk),
            fixture.event(8, .standardOutput, output: Data("done\nnext".utf8)),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        let messages = try drain(RunBrokerProjectionOutbox(ledger: fixture.ledger))
        let streams = messages.compactMap { message -> RunBrokerApplicationStreamRecord? in
            guard case .supervisor(let projection) = message.event else { return nil }
            return projection.stream
        }

        #expect(streams.count == 6)
        #expect(streams[0].startsLogicalLine)
        #expect(streams[0].trailingFragmentByteCount == 32_768)
        #expect(!streams[1].startsLogicalLine)
        #expect(streams[1].trailingFragmentByteCount == 65_536)
        #expect(streams[3].trailingFragmentByteCount == 131_072)
        #expect(!streams[3].fragmentTruncated)
        #expect(streams[4].trailingFragmentByteCount == 131_072)
        #expect(streams[4].fragmentTruncated)
        #expect(!streams[5].startsLogicalLine)
        #expect(streams[5].trailingFragmentByteCount == 4)
        #expect(!streams[5].fragmentTruncated)
        for stream in streams { try stream.validate() }
    }

    @Test("signaled and wait-failed terminal evidence preserve supervisor exit truth")
    func terminalEvidenceMatchesSupervisorSchema() throws {
        let signaled = try BrokerFixture()
        signaled.transport.events = [
            signaled.event(1, .supervisorReady),
            signaled.event(2, .providerStarted),
            terminalEvent(
                sequence: 3,
                exitCode: 137,
                signal: SIGKILL,
                reason: .signaled
            ),
        ]
        _ = try signaled.orchestrator().start(signaled.request())
        let signaledMessages = try drain(RunBrokerProjectionOutbox(ledger: signaled.ledger))
        let signaledTerminal = try #require(terminal(in: signaledMessages))
        #expect(signaledTerminal.outcome == .signaled)
        #expect(signaledTerminal.exitCode == 137)
        #expect(signaledTerminal.terminationSignal == SIGKILL)
        try signaledTerminal.validate()

        let waitFailed = try BrokerFixture()
        waitFailed.transport.events = [
            waitFailed.event(1, .supervisorReady),
            waitFailed.event(2, .providerStarted),
            terminalEvent(
                sequence: 3,
                exitCode: -7,
                signal: nil,
                reason: .waitFailed
            ),
        ]
        _ = try waitFailed.orchestrator().start(waitFailed.request())
        let waitMessages = try drain(RunBrokerProjectionOutbox(ledger: waitFailed.ledger))
        let waitTerminal = try #require(terminal(in: waitMessages))
        #expect(waitTerminal.outcome == .waitFailed)
        #expect(waitTerminal.exitCode == -7)
        try waitTerminal.validate()
    }

    @Test("stored projection codec rejects future shape, unknown keys, and digest corruption")
    func projectionGoldenAndCorruption() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let row = try #require(try fixture.ledger.outbox().first)
        let current = try RunLedgerOutboxProjectionCodec.encode(row.projection)
        #expect(try RunLedgerOutboxProjectionCodec.decode(
            payload: current.payload,
            sha256: current.sha256
        ) == row.projection)

        var futureObject = try #require(
            JSONSerialization.jsonObject(with: current.payload) as? [String: Any]
        )
        futureObject["schemaVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: futureObject, options: [.sortedKeys])
        #expect(throws: (any Error).self) {
            _ = try RunLedgerOutboxProjectionCodec.decode(
                payload: future,
                sha256: Data(SHA256.hash(data: future))
            )
        }

        var unknownObject = try #require(
            JSONSerialization.jsonObject(with: current.payload) as? [String: Any]
        )
        unknownObject["futureField"] = true
        let unknown = try JSONSerialization.data(withJSONObject: unknownObject, options: [.sortedKeys])
        #expect(throws: (any Error).self) {
            _ = try RunLedgerOutboxProjectionCodec.decode(
                payload: unknown,
                sha256: Data(SHA256.hash(data: unknown))
            )
        }

        var wrongDigest = current.sha256
        wrongDigest[wrongDigest.startIndex] ^= 0xff
        #expect(throws: RunLedgerError.self) {
            _ = try RunLedgerOutboxProjectionCodec.decode(
                payload: current.payload,
                sha256: wrongDigest
            )
        }
    }

    @Test("projection message rejects a ledger kind that disagrees with its typed case")
    func eventKindMustMatchTypedCase() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let message = try #require(try RunBrokerProjectionOutbox(ledger: fixture.ledger).next())
        #expect(throws: RunBrokerApplicationContractError.invalidProjectionMessage) {
            try RunBrokerApplicationProjectionMessage(
                sequence: message.sequence,
                messageID: message.messageID,
                eventKind: "operation.claimed",
                event: message.event,
                occurredAt: message.occurredAt
            ).validate()
        }
    }

    private func drain(
        _ outbox: RunBrokerProjectionOutbox
    ) throws -> [RunBrokerApplicationProjectionMessage] {
        var messages: [RunBrokerApplicationProjectionMessage] = []
        while let message = try outbox.next() {
            try message.validate()
            messages.append(message)
            _ = try outbox.acknowledge(.init(
                sequence: message.sequence,
                messageID: message.messageID
            ))
        }
        return messages
    }

    private func terminal(
        in messages: [RunBrokerApplicationProjectionMessage]
    ) -> RunBrokerApplicationTerminalEvidence? {
        messages.lazy.compactMap { message in
            guard case .supervisor(let projection) = message.event else { return nil }
            return projection.terminal
        }.last
    }

    private func terminalEvent(
        sequence: UInt64,
        exitCode: Int32,
        signal: Int32?,
        reason: RunSupervisorTerminationReason
    ) -> RunSupervisorEvent {
        .init(
            sequence: sequence,
            id: brokerUUID(UInt8(20 + sequence)),
            timestamp: brokerTestDate.addingTimeInterval(TimeInterval(sequence)),
            kind: .providerExited,
            payload: .init(
                exitCode: exitCode,
                terminationSignal: signal,
                terminationReason: reason
            )
        )
    }
}

private enum ProjectionConcurrentResultError: Error {
    case missingResult
}

private final class ProjectionConcurrentResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var error: (any Error)?

    func capture(_ operation: () throws -> Value) {
        lock.lock()
        defer { lock.unlock() }
        do {
            value = try operation()
        } catch {
            self.error = error
        }
    }

    func get() throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        guard let value else { throw ProjectionConcurrentResultError.missingResult }
        return value
    }
}
