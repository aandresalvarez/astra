import Foundation

/// Immutable observations of one process attempt. Activity is deliberately not
/// labelled progress: the investigator must explain what actually advanced.
struct RuntimeSupervisionObservation: Codable, Sendable, Equatable {
    var progressRevision: Int
    var quietSeconds: Int
    var stdoutBytes: Int
    var stderrBytes: Int
    var unknownFrames: Int
    var activeTools: [String]
    var managedJobs: [String]
    var recentOutput: String
}

struct RuntimeSupervisionFiles: Codable, Sendable, Equatable {
    var metadata: [String: String] = [:]
    var unavailable: String?
    var coverageNotes: [String] = []

    func changes(since baseline: Self) -> [String] {
        guard unavailable == nil, baseline.unavailable == nil else { return [] }
        return Set(metadata.keys).union(baseline.metadata.keys).filter {
            metadata[$0] != baseline.metadata[$0]
        }.sorted()
    }

    func recentChanges(since baseline: Self, quietSeconds: Int, now: Date = Date()) -> [String] {
        let earliest = now.timeIntervalSince1970 - Double(quietSeconds) - 1
        return changes(since: baseline).filter { path in
            guard let row = metadata[path] else { return false } // deletion time is unknown
            return row.split(separator: "|").prefix(2).compactMap { Double($0) }.contains { $0 >= earliest }
        }
    }
}

struct RuntimeSupervisionEvidence: Codable, Sendable {
    let goal: String
    let runtime: String
    let observation: RuntimeSupervisionObservation
    struct FileDelta: Codable, Sendable {
        let path: String
        let previousBytes: Int64?
        let currentBytes: Int64?
        let changedSecondsAgo: Int
    }
    let changedFiles: [FileDelta]
    let fileCoverage: String
    let remoteCoverage: String
    var postAssessmentFileChanges: [String]? = nil
    var postAssessmentFileCoverage: String? = nil

    var supportsProgress: Bool { changedFiles.contains { $0.changedSecondsAgo <= 120 } }
    var supportsWaiting: Bool {
        !observation.activeTools.isEmpty || !observation.managedJobs.isEmpty
    }
}

struct RuntimeSupervisionAssessment: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case progressing, waiting, suspectedStalled, inconclusive
    }
    var assessment: Kind
    var explanation: String
    var evidenceIDs: [String]

    static func inconclusive(_ reason: String) -> Self {
        .init(assessment: .inconclusive, explanation: reason, evidenceIDs: [])
    }

    static func decode(_ output: String) -> Self? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4_096 else { return nil }
        // Claude may fence its JSON even when asked for JSON only. Accept one
        // complete wrapper, never search surrounding prose for a usable verdict.
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: .newlines)
            guard lines.count >= 3, let first = lines.first,
                  ["```json", "```"].contains(first), lines.last == "```" else { return nil }
            text = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.explanation.isEmpty, value.explanation.count <= 600,
              value.evidenceIDs.count <= 3,
              value.evidenceIDs.allSatisfy({ ["runtime", "files", "remote"].contains($0) }) else { return nil }
        return value
    }
}

struct RuntimeSupervisionReport: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case checking, progressing, waiting, inconclusive, resumed, stopping
    }
    let attemptID: UUID
    let sequence: Int
    let phase: Phase
    let message: String
    let assessment: RuntimeSupervisionAssessment?
    let evidence: RuntimeSupervisionEvidence?
    let reservedTokens: Int
    var investigatorRuntime: String? = nil
    var investigatorModel: String? = nil
}
