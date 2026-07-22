import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger canonical persisted bytes")
struct RunLedgerCanonicalPayloadTests {
    @Test("Nested, whitespace, key-order, and date tampering fail closed on replay")
    func noncanonicalPersistedPayloadsFailClosed() throws {
        let mutations: [(String, (Data) throws -> Data)] = [
            ("nested unknown key", addNestedUnknownKey),
            ("whitespace", addWhitespace),
            ("key order", reorderTopLevelKeys),
            ("noncanonical date", spellZeroDateAsNegativeZero),
        ]

        for (name, mutate) in mutations {
            let fixture = try LedgerFixture()
            defer { fixture.cleanup() }
            let ledger = try fixture.open()
            defer { try? ledger.close() }
            let authority = fixture.authority(9_000, epoch: 1)
            let manifest = ExecutionLaunchManifest(
                installationID: fixture.configuration.installationID,
                storeID: ledger.identity.storeID,
                executionID: executionID(9_001),
                taskID: fixedUUID(9_002),
                authority: authority,
                configuration: .init(
                    runtimeID: .codexCLI,
                    executablePath: "/usr/local/bin/codex",
                    workingDirectory: "/workspace/repo",
                    configurationRevision: "sha256:canonical-test"
                ),
                declaredEffects: [.computeOnly],
                createdAt: Date(timeIntervalSince1970: 0)
            )
            let envelope = RunLedgerEventEnvelope(
                eventID: fixture.eventID(9_003),
                occurredAt: Date(timeIntervalSince1970: 0),
                event: .executionAdmitted(
                    manifest: manifest,
                    primaryOperationID: fixture.operationID(9_004)
                )
            )
            let canonical = try RunLedgerCodec.canonicalize(envelope).1
            let tampered = try mutate(canonical)
            #expect(tampered != canonical, "Mutation did not change bytes: \(name)")
            guard case .corrupt = monitorLedgerError({
                _ = try RunLedgerCodec.envelope(eventID: envelope.eventID, from: tampered)
            }) else {
                Issue.record("Codec accepted noncanonical persisted bytes: \(name)")
                continue
            }

            try ledger.append(envelope)
            #expect(try ledger.events().count == 1)
            #expect(try ledger.replayedProjection() == ledger.projection())
            #expect(ledger.verifyHealth().status == .healthy)
            try replacePersistedEventPayload(
                at: fixture.configuration.databaseURL,
                sequence: 1,
                with: tampered
            )

            guard case .corrupt = ledgerError({ _ = try ledger.events() }) else {
                Issue.record("Journal read accepted tampered bytes: \(name)")
                continue
            }
            guard case .corrupt = ledgerError({ _ = try ledger.replayedProjection() }) else {
                Issue.record("Replay accepted tampered bytes: \(name)")
                continue
            }
            #expect(ledger.verifyHealth().status == .corrupt)
        }
    }
}

private func addNestedUnknownKey(_ data: Data) throws -> Data {
    var root = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    var event = try #require(root["event"] as? [String: Any])
    var manifest = try #require(event["manifest"] as? [String: Any])
    var configuration = try #require(manifest["configuration"] as? [String: Any])
    configuration["futureNestedField"] = true
    manifest["configuration"] = configuration
    event["manifest"] = manifest
    root["event"] = event
    return try JSONSerialization.data(
        withJSONObject: root,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func addWhitespace(_ data: Data) throws -> Data {
    let string = String(decoding: data, as: UTF8.self)
    return Data(("{ " + string.dropFirst()).utf8)
}

private func reorderTopLevelKeys(_ data: Data) throws -> Data {
    let root = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let event = try #require(root["event"])
    let occurredAt = try #require(root["occurredAt"] as? NSNumber)
    let schemaVersion = try #require(root["schemaVersion"] as? NSNumber)
    let eventData = try JSONSerialization.data(
        withJSONObject: event,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let eventJSON = String(decoding: eventData, as: UTF8.self)
    return Data(
        "{\"schemaVersion\":\(schemaVersion),\"occurredAt\":\(occurredAt),\"event\":\(eventJSON)}".utf8
    )
}

private func spellZeroDateAsNegativeZero(_ data: Data) throws -> Data {
    let canonical = String(decoding: data, as: UTF8.self)
    let tampered = canonical.replacingOccurrences(
        of: "\"occurredAt\":0",
        with: "\"occurredAt\":-0"
    )
    return Data(tampered.utf8)
}

private func replacePersistedEventPayload(
    at databaseURL: URL,
    sequence: Int64,
    with data: Data
) throws {
    let hex = data.map { String(format: "%02x", $0) }.joined()
    try executeSQLite(
        databaseURL,
        """
        DROP TRIGGER events_no_update;
        UPDATE events SET payload = X'\(hex)' WHERE sequence = \(sequence);
        CREATE TRIGGER events_no_update BEFORE UPDATE ON events
        BEGIN SELECT RAISE(ABORT, 'event journal is append-only'); END;
        """
    )
}
