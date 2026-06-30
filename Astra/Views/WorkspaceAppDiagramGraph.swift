import SwiftUI

/// A laid-out node graph for a Workspace App `diagram` widget — replaces the flat from→to edge list
/// with positioned node boxes connected by edges. Nodes are layered by longest-path depth (a simple
/// Sugiyama-style layering); EVERY edge is still drawn as a line, so unlike a naive vertical stack
/// this never loses an edge — cyclic/branching graphs degrade in layout quality but stay complete.
struct WorkspaceAppDiagramGraph: View {
    let edges: [WorkspaceAppDiagramPresentation.Edge]

    struct Node: Identifiable, Equatable {
        let id: String
        let layer: Int
        let indexInLayer: Int
        let layerCount: Int
    }

    private static let layerHeight: CGFloat = 64
    private static let nodeHalfHeight: CGFloat = 15

    var body: some View {
        let nodes = Self.layout(edges: edges)
        let layerCount = (nodes.map(\.layer).max() ?? 0) + 1
        GeometryReader { proxy in
            let width = proxy.size.width
            let positions = Dictionary(uniqueKeysWithValues: nodes.map { node in
                (node.id, CGPoint(
                    x: width * (CGFloat(node.indexInLayer) + 0.5) / CGFloat(max(node.layerCount, 1)),
                    y: CGFloat(node.layer) * Self.layerHeight + 24
                ))
            })
            ZStack {
                ForEach(edges) { edge in
                    if let from = positions[edge.from], let to = positions[edge.to] {
                        Path { path in
                            path.move(to: CGPoint(x: from.x, y: from.y + Self.nodeHalfHeight))
                            path.addLine(to: CGPoint(x: to.x, y: to.y - Self.nodeHalfHeight))
                        }
                        .stroke(Stanford.lagunita.opacity(0.5), lineWidth: 1.5)
                    }
                }
                ForEach(nodes) { node in
                    Text(node.id)
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Stanford.fog)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Stanford.lagunita.opacity(0.4), lineWidth: 1)
                        )
                        .position(positions[node.id] ?? .zero)
                }
            }
        }
        .frame(height: CGFloat(layerCount) * Self.layerHeight)
    }

    /// Unique nodes (first-appearance order), layered by longest-path relaxation. The relaxation is
    /// capped at `nodes.count` passes so a cycle terminates with a finite (if imperfect) layering
    /// rather than looping forever.
    static func layout(edges: [WorkspaceAppDiagramPresentation.Edge]) -> [Node] {
        var order: [String] = []
        var seen = Set<String>()
        for edge in edges {
            for name in [edge.from, edge.to] where seen.insert(name).inserted { order.append(name) }
        }
        guard !order.isEmpty else { return [] }

        var layer = Dictionary(uniqueKeysWithValues: order.map { ($0, 0) })
        for _ in 0..<order.count {
            var changed = false
            for edge in edges {
                let candidate = (layer[edge.from] ?? 0) + 1
                if candidate > (layer[edge.to] ?? 0) {
                    layer[edge.to] = candidate
                    changed = true
                }
            }
            if !changed { break }
        }

        let grouped = Dictionary(grouping: order, by: { layer[$0] ?? 0 })
        var nodes: [Node] = []
        for layerIndex in grouped.keys.sorted() {
            let ids = grouped[layerIndex] ?? []
            for (index, id) in ids.enumerated() {
                nodes.append(Node(id: id, layer: layerIndex, indexInLayer: index, layerCount: ids.count))
            }
        }
        return nodes
    }
}
