import ASTRACore
import ASTRARunLedger
import Foundation
import RunBrokerKit
import Testing
@testable import RunBrokerService

@Suite("RunBroker projection payload single-copy storage", .serialized)
struct RunBrokerProjectionPayloadSingleCopyTests {
    @Test("Stream bytes are stored once and reconstructed exactly for delivery")
    func streamBytesSingleCopy() throws {
        let fixture = try BrokerFixture()
        let chunk = Data(repeating: 0x61, count: 32_768)
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
            fixture.event(3, .standardOutput, output: chunk),
        ]
        _ = try fixture.orchestrator().start(fixture.request())

        let stored = try #require(try fixture.ledger.outbox().first(where: { row in
            guard case .supervisor(let value) = row.projection else { return false }
            return value.observation.kind == .standardOutput
        }))
        guard case .supervisor(let projected) = stored.projection else {
            Issue.record("Expected stored supervisor projection")
            return
        }
        #expect(projected.observation.output == nil)
        #expect(projected.stream?.bytes == chunk)

        let encoded = try RunLedgerOutboxProjectionCodec.encode(stored.projection).payload
        let base64 = chunk.base64EncodedString()
        let payloadText = try #require(String(data: encoded, encoding: .utf8))
        #expect(payloadText.components(separatedBy: base64).count - 1 == 1)
        #expect(encoded.count < base64.utf8.count + 4_096)

        let delivery = RunBrokerProjectionOutbox(ledger: fixture.ledger)
        var delivered: RunBrokerApplicationProjectionMessage?
        while let message = try delivery.next() {
            if case .supervisor(let value) = message.event,
               value.observation.kind == .standardOutput {
                delivered = message
                break
            }
            _ = try delivery.acknowledge(.init(
                sequence: message.sequence,
                messageID: message.messageID
            ))
        }
        guard let delivered,
              case .supervisor(let value) = delivered.event else {
            Issue.record("Expected delivered stream projection")
            return
        }
        #expect(value.observation.output == chunk)
        #expect(value.stream?.bytes == chunk)
        try delivered.validate()
    }
}
