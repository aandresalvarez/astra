import Testing
@testable import ASTRA

@Suite("Workspace App Diagram Graph")
struct WorkspaceAppDiagramGraphTests {
    private func edge(_ from: String, _ to: String) -> WorkspaceAppDiagramPresentation.Edge {
        WorkspaceAppDiagramPresentation.Edge(from: from, to: to)
    }

    @Test("layered layout places each node at its longest-path depth and keeps every node")
    func layering() {
        let nodes = WorkspaceAppDiagramGraph.layout(edges: [edge("a", "b"), edge("b", "c"), edge("b", "d")])
        func layer(_ id: String) -> Int? { nodes.first { $0.id == id }?.layer }
        #expect(nodes.count == 4)
        #expect(layer("a") == 0)
        #expect(layer("b") == 1)
        #expect(layer("c") == 2)
        #expect(layer("d") == 2)
    }

    @Test("a cycle terminates with a finite layering (no infinite loop)")
    func cycleTerminates() {
        let nodes = WorkspaceAppDiagramGraph.layout(edges: [edge("a", "b"), edge("b", "a")])
        #expect(nodes.count == 2)
    }

    @Test("empty edges produce no nodes")
    func empty() {
        #expect(WorkspaceAppDiagramGraph.layout(edges: []).isEmpty)
    }
}
