import ApplicationServices
import Foundation
import Testing
@testable import DevScaleBenchmarkSupport

@Suite("Benchmark AX read and readiness semantics")
struct AXReadinessTests {
    func error(_ value: AXError) -> AXValue {
        var value = value
        return AXValueCreate(.axError, &value)!
    }

    func batch(role: Any = "AXGroup", title: Any = NSNull(), description: Any = NSNull(), identifier: Any = NSNull(),
               value: Any = NSNull(), children: Any = [AXUIElement]()) -> AXReadiness.Batch {
        AXReadiness.Batch(status: .success, values: [role, title, description, identifier, value, children])
    }

    @Test("A real per-attribute AX error cannot prove an empty subtree")
    func childError() {
        let root = AXUIElementCreateApplication(getpid())
        let raw = error(.cannotComplete)
        var decoded = AXError.success
        #expect(AXValueGetValue(raw, .axError, &decoded))
        #expect(decoded.rawValue == -25204)
        let result = AXReadiness.find(root, "Panel", reader: { _ in batch(children: raw) })
        #expect(!result.complete)
        #expect(!result.isReady(present: false))
        #expect(!result.isReady(present: true))
    }

    @Test("Unknown, still-present, then closed observations only finish on actual closure")
    func closeSequence() {
        let root = AXUIElementCreateApplication(getpid())
        let panel = AXUIElementCreateApplication(getpid() + 1)
        let observations = [batch(children: error(.cannotComplete)), batch(children: [panel]), batch()]
        let ready = observations.map { observation in
            AXReadiness.find(root, "Panel", reader: { element in
                CFEqual(element, root) ? observation : batch(title: "Panel")
            }).isReady(present: false)
        }
        #expect(ready == [false, false, true])
    }

    @Test("Transient failures in title, role, identifier and value require another read")
    func matchingErrors() {
        let root = AXUIElementCreateApplication(getpid())
        let cases = [("Panel", batch(title: error(.cannotComplete))),
                     ("Panel", batch(description: error(.cannotComplete))),
                     ("role:AXTextArea", batch(role: error(.cannotComplete))),
                     ("scroll:TaskSidebar", batch(role: "AXScrollArea", identifier: error(.cannotComplete))),
                     ("contains:Panel", batch(value: error(.cannotComplete)))]
        for (needle, observation) in cases {
            let result = AXReadiness.find(root, needle, reader: { _ in observation })
            #expect(!result.complete)
            #expect(!result.isReady(present: false))
        }
    }

    @Test("Other attribute errors cannot be mistaken for missing children")
    func otherErrors() {
        let root = AXUIElementCreateApplication(getpid())
        for failure in [AXError.failure, .invalidUIElement, .notImplemented, .illegalArgument] {
            #expect(!AXReadiness.find(root, "Panel", reader: { _ in batch(children: error(failure)) }).isReady(present: false))
        }
    }

    @Test("Unsupported, no-value and CFNull attributes are genuine missing values")
    func missingAttributes() {
        let root = AXUIElementCreateApplication(getpid())
        for missing in [error(.attributeUnsupported) as Any, error(.noValue), NSNull()] {
            let result = AXReadiness.find(root, "Panel", reader: { _ in batch(title: missing, value: missing, children: missing) })
            #expect(result.complete)
            #expect(result.isReady(present: false))
        }
    }

    @Test("Failed or malformed batches and invalid child arrays stay incomplete")
    func invalidReads() {
        let root = AXUIElementCreateApplication(getpid())
        let observations = [AXReadiness.Batch(status: .cannotComplete, values: nil),
                            AXReadiness.Batch(status: .invalidUIElement, values: nil),
                            AXReadiness.Batch(status: .success, values: ["AXGroup"]),
                            batch(children: "not children"), batch(children: [error(.cannotComplete)])]
        for observation in observations {
            #expect(!AXReadiness.find(root, "Panel", reader: { _ in observation }).isReady(present: false))
        }
    }

    @Test("A positive witness and irrelevant optional errors do not block readiness")
    func positiveAndIrrelevant() {
        let root = AXUIElementCreateApplication(getpid())
        #expect(AXReadiness.find(root, "Panel", reader: { _ in
            batch(title: error(.cannotComplete), identifier: "Panel", children: error(.cannotComplete))
        }).isReady(present: true))
        #expect(AXReadiness.find(root, "role:AXTextArea", reader: { _ in
            batch(title: error(.cannotComplete), value: error(.cannotComplete))
        }).isReady(present: false))
        #expect(AXReadiness.find(root, "Panel", reader: { _ in batch(value: 42) }).isReady(present: false))
    }

    @Test("Uncertain sidebar scope and traversal limits cannot establish absence")
    func scopeAndLimit() {
        let root = AXUIElementCreateApplication(getpid())
        #expect(!AXReadiness.find(root, "TaskRow_Panel", reader: { _ in
            batch(role: "AXScrollArea", identifier: error(.cannotComplete))
        }).isReady(present: false))
        #expect(!AXReadiness.find(root, "Panel", reader: { _ in batch(children: [root]) }).complete)
        #expect(AXReadiness.find(root, "Panel", reader: { _ in
            batch(role: "AXMenuBar", children: error(.cannotComplete))
        }).isReady(present: false))
    }

    @Test("Typed selectors ignore unrelated failures and still require their own attributes")
    func typedSelectors() {
        let root = AXUIElementCreateApplication(getpid())
        let composer = batch(role: "AXMenuButton", description: "Composer actions",
                             identifier: error(.failure), value: error(.attributeUnsupported))
        for needle in ["value:contains:Synthetic message", "content:contains:Synthetic message", "label:Workspace Configuration", "id:AXButton:FilesShelfBrowseButton"] {
            #expect(AXReadiness.find(root, needle, reader: { _ in composer }).isReady(present: false))
        }
        #expect(!AXReadiness.find(root, "id:AXMenuButton:Composer", reader: { _ in composer }).isReady(present: false))
        #expect(!AXReadiness.find(root, "value:contains:Synthetic message", reader: { _ in
            batch(value: error(.cannotComplete))
        }).isReady(present: false))
        #expect(AXReadiness.find(root, "value:contains:Synthetic message", reader: { _ in
            batch(identifier: error(.failure), value: "Synthetic message")
        }).isReady(present: true))
        #expect(AXReadiness.find(root, "id:AXButton:FilesShelfBrowseButton", reader: { _ in
            batch(role: "AXButton", title: error(.cannotComplete), identifier: "FilesShelfBrowseButton")
        }).isReady(present: true))
    }

    @Test("Visible-content selectors support combined message descriptions and text values")
    func combinedMessageContent() {
        let root = AXUIElementCreateApplication(getpid())
        for observation in [batch(role: "AXUnknown", description: "Your message: Synthetic 426/0.", identifier: error(.failure)),
                            batch(identifier: error(.failure), value: "Synthetic 426/0.")] {
            #expect(AXReadiness.find(root, "content:contains:Synthetic 426/0.", reader: { _ in observation }).isReady(present: true))
        }
        #expect(!AXReadiness.find(root, "content:contains:Synthetic 426/0.", reader: { _ in
            batch(description: error(.cannotComplete))
        }).isReady(present: false))
    }
}

@Suite("Benchmark goal metadata")
struct FixtureGoalTests {
    @Test("Full/no-files retain the measured 5,376-byte goal workload")
    func fullGoals() {
        let goals = (0..<2195).map { FixtureGoals.make(index: $0, sidebarOnly: false) }
        #expect(FixtureGoals.uniformByteCount(goals) == 5376)
        #expect(goals.allSatisfy { $0 == String(repeating: "Synthetic goal. ", count: 336) })
    }

    @Test("Sidebar goals retain their distinct 5,040-byte workload")
    func sidebarGoals() {
        let goals = (0..<2195).map { FixtureGoals.make(index: $0, sidebarOnly: true) }
        #expect(FixtureGoals.uniformByteCount(goals) == 5040)
        #expect(Set(goals).count == 2195)
    }

    @Test("Metadata uses UTF-8 size and never labels mixed sizes as uniform")
    func utf8() {
        #expect(FixtureGoals.uniformByteCount(["é"]) == 2)
        #expect(FixtureGoals.uniformByteCount(["a", "é"]) == nil)
        #expect(FixtureGoals.uniformByteCount([String]()) == nil)
    }
}
