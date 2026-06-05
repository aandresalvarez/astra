import Testing
import Foundation
@testable import ASTRA

@Suite("File Change Storage")
struct FileChangeTests {

    @Test("Write change JSON round-trip")
    func writeChangeRoundTrip() throws {
        let change = StoredFileChange(
            id: UUID(), path: "/tmp/test.swift", changeType: "Write",
            content: "let x = 1", oldString: nil, newString: nil, timestamp: Date()
        )
        let encoded = try JSONEncoder().encode([change])
        let json = String(data: encoded, encoding: .utf8)!
        #expect(json.contains("test.swift"))
        #expect(json.contains("Write"))

        let decoded = try JSONDecoder().decode([StoredFileChange].self, from: encoded)
        #expect(decoded.count == 1)
        #expect(decoded[0].path == "/tmp/test.swift")
        #expect(decoded[0].content == "let x = 1")
        #expect(decoded[0].kind == .write)
    }

    @Test("Edit change encoding")
    func editChangeEncoding() throws {
        let write = StoredFileChange(
            id: UUID(), path: "/tmp/a.swift", changeType: "Write",
            content: "hello", oldString: nil, newString: nil, timestamp: Date()
        )
        let edit = StoredFileChange(
            id: UUID(), path: "/tmp/b.swift", changeType: "Edit",
            content: nil, oldString: "let x = 1", newString: "let x = 2", timestamp: Date()
        )
        let encoded = try JSONEncoder().encode([write, edit])
        let decoded = try JSONDecoder().decode([StoredFileChange].self, from: encoded)
        #expect(decoded.count == 2)
        #expect(decoded[1].changeType == "Edit")
        #expect(decoded[1].kind == .edit)
        #expect(decoded[1].oldString == "let x = 1")
        #expect(decoded[1].newString == "let x = 2")
    }

    @Test("Empty JSON array decoding")
    func emptyArray() throws {
        let data = "[]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([StoredFileChange].self, from: data)
        #expect(decoded.isEmpty)
    }

    @Test("Historic change type strings map to typed kinds")
    func historicChangeTypeStringsMapToTypedKinds() throws {
        let data = """
        [
          {"id":"00000000-0000-0000-0000-000000000001","path":"/tmp/a.md","changeType":"Write","content":"A","oldString":null,"newString":null,"timestamp":"2026-06-05T12:00:00Z"},
          {"id":"00000000-0000-0000-0000-000000000002","path":"/tmp/b.md","changeType":"Edit","content":null,"oldString":"A","newString":"B","timestamp":"2026-06-05T12:00:00Z"},
          {"id":"00000000-0000-0000-0000-000000000003","path":"/tmp/c.md","changeType":"rename","content":null,"oldString":null,"newString":null,"timestamp":"2026-06-05T12:00:00Z"}
        ]
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([StoredFileChange].self, from: data)

        #expect(decoded.map(\.kind) == [.write, .edit, .unknown])
        #expect(decoded.map(\.changeType) == ["Write", "Edit", "rename"])
    }

    @Test("Task run file changes exposes decode diagnostics")
    func taskRunFileChangesExposesDecodeDiagnostics() {
        let task = AgentTask(title: "Decode", goal: "Decode file changes")
        let run = TaskRun(task: task)
        run.fileChangesJSON = "not-json"

        switch run.fileChangesDecodeResult {
        case .success:
            Issue.record("Expected malformed file changes JSON to fail")
        case .failure(let error):
            guard case .decodingFailed = error else {
                Issue.record("Expected decoding failure, got \(error)")
                return
            }
        }
        #expect(run.fileChanges.isEmpty)
    }
}
