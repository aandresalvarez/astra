import Testing
import Foundation

// Mirrors StoredFileChange from TaskRun.swift
private struct StoredFileChange: Codable, Hashable, Identifiable {
    let id: UUID
    let path: String
    let changeType: String
    let content: String?
    let oldString: String?
    let newString: String?
    let timestamp: Date
}

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
        #expect(decoded[1].oldString == "let x = 1")
        #expect(decoded[1].newString == "let x = 2")
    }

    @Test("Empty JSON array decoding")
    func emptyArray() throws {
        let data = "[]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([StoredFileChange].self, from: data)
        #expect(decoded.isEmpty)
    }
}
