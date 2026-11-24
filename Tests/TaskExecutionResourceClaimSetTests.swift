import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Versioned durable resource claims")
@MainActor
struct TaskExecutionResourceClaimSetTests {
    private let claims = [
        TaskExecutionResourceClaim(kind: .workspace, key: "/tmp/astra-claim-set", access: .shared, readConsistency: .live),
        TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: "/tmp/astra-claim-set/.git", access: .exclusive),
        TaskExecutionResourceClaim(kind: .remoteDirectory, key: "host:22 ~deploy/service", access: .exclusive)
    ]

    @Test("A claim set round-trips through its versioned envelope")
    func envelopeRoundTrips() throws {
        let json = try #require(TaskExecutionResourceClaimSet(claims: claims).encodedJSON())
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["version"] as? Int == TaskExecutionResourceClaimSet.currentVersion)
        #expect((object["claims"] as? [Any])?.count == claims.count)

        let decoded = try #require(TaskExecutionResourceClaimSet.decode(json))
        #expect(decoded.version == TaskExecutionResourceClaimSet.currentVersion)
        #expect(decoded.claims == claims)
    }

    @Test("A bare array written before the envelope still decodes, as version 0")
    func legacyArrayDecodes() throws {
        let legacy = String(decoding: try JSONEncoder().encode(claims), as: UTF8.self)
        let decoded = try #require(TaskExecutionResourceClaimSet.decode(legacy))
        #expect(decoded.version == TaskExecutionResourceClaimSet.legacyVersion)
        #expect(decoded.claims == claims)

        // The column's default, and a row a hand-written fixture leaves empty.
        #expect(TaskExecutionResourceClaimSet.decode("[]")?.claims == [])
    }

    @Test("Unreadable and unknown-version claim sets fail closed", arguments: [
        "{", "", "null", "{}", #"{"claims":[]}"#,
        #"{"version":0,"claims":[]}"#,
        #"{"version":2,"claims":[]}"#,
        #"{"version":1,"claims":[{"kind":"workspace","key":"/tmp/x","access":"future_access"}]}"#,
        #"[{"kind":"future_kind","key":"/tmp/x","access":"shared"}]"#
    ])
    func unreadableClaimSetsAreNil(json: String) {
        #expect(TaskExecutionResourceClaimSet.decode(json) == nil)
    }

    @Test("A request writes the envelope and reads both forms")
    func requestPersistsTheEnvelope() throws {
        let task = AgentTask(title: "Claims", goal: "Update the parser.",
                             workspace: Workspace(name: "Claims", primaryPath: "/tmp/astra-claim-set"))
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceClaims: claims)

        #expect(request.decodedResourceClaimSet?.version == TaskExecutionResourceClaimSet.currentVersion)
        #expect(request.resourceClaims == claims)
        // The snapshot carries the same bytes, so an imported request keeps its version.
        let imported = TaskTurnRequest(snapshot: request.snapshot, task: task)
        #expect(imported.resourceClaimsJSON == request.resourceClaimsJSON)
        #expect(imported.resourceClaims == claims)

        // A row written by an earlier build.
        request.resourceClaimsJSON = String(decoding: try JSONEncoder().encode(claims), as: UTF8.self)
        #expect(request.decodedResourceClaimSet?.version == TaskExecutionResourceClaimSet.legacyVersion)
        #expect(request.resourceClaims == claims)
        #expect(TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task).contains(claims[0]))

        // An envelope from a newer build is unreadable: admission keeps one
        // exclusive workspace lease, and nothing reads it as claim-free.
        request.resourceClaimsJSON = #"{"version":99,"claims":[]}"#
        #expect(request.decodedResourceClaims == nil)
        let fallback = TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task)
        #expect(fallback.contains { $0.kind == .workspace && $0.access == .exclusive })
    }

    @Test("Submission computes the same claims it did before the envelope")
    func envelopeDoesNotChangeComputedClaims() throws {
        let task = AgentTask(title: "Claims", goal: "Update the parser.",
                             workspace: Workspace(name: "Claims", primaryPath: "/tmp/astra-claim-set"))
        let computed = TaskExecutionResourceClaimResolver.claims(for: task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceClaims: computed)
        #expect(request.resourceClaims == computed)
    }
}
