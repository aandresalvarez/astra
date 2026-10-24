import Foundation

/// Inspect each tree without Git recursion before asking Git for a recursive
/// listing. Object byte limits alone cannot bound nesting or expanded paths.
enum PluginSourceTreeBudget {
    static let maximumTrees = 1_024
    static let maximumDepth = 64
    static let maximumPathBytes = 1_024

    private struct Entry {
        let nameBytes: Int
        let subtree: String?
    }

    static func validate(
        metadata: String, maximumEntries: Int,
        readTree: (String) async throws -> String
    ) async throws {
        let trees = metadata.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count == 3 && fields[1] == "tree" ? String(fields[0]) : nil
        }
        guard !trees.isEmpty, trees.count <= maximumTrees, Set(trees).count == trees.count,
              trees.allSatisfy(isObjectID) else { throw PluginSourceFetchError.tooLarge }
        let treeIDs = Set(trees)
        var graph: [String: [Entry]] = [:]
        var entryCount = 0
        for tree in trees {
            try Task.checkCancellation()
            let listing = try await readTree(tree)
            guard listing.isEmpty || listing.hasSuffix("\0") else { throw PluginSourceFetchError.tooLarge }
            var entries: [Entry] = []
            for record in listing.split(separator: "\0", omittingEmptySubsequences: true) {
                guard let tab = record.firstIndex(of: "\t") else { throw PluginSourceFetchError.tooLarge }
                let header = record[..<tab].split(separator: " ")
                let name = record[record.index(after: tab)...]
                guard header.count == 3, ["blob", "tree", "commit"].contains(header[1]),
                      isObjectID(String(header[2])), !name.isEmpty, name != ".", name != "..",
                      !name.contains("/"), name.utf8.count <= 255 else { throw PluginSourceFetchError.tooLarge }
                let subtree = header[1] == "tree" ? String(header[2]) : nil
                guard subtree.map(treeIDs.contains) ?? true else { throw PluginSourceFetchError.tooLarge }
                entryCount += 1
                guard entryCount <= maximumEntries else { throw PluginSourceFetchError.tooLarge }
                entries.append(Entry(nameBytes: name.utf8.count, subtree: subtree))
            }
            graph[tree] = entries
        }
        struct Dimensions { let depth: Int; let path: Int; let entries: Int }
        var visiting = Set<String>()
        var measured: [String: Dimensions] = [:]
        func dimensions(_ id: String, at depth: Int) -> Dimensions? {
            guard depth <= maximumDepth else { return nil }
            if let cached = measured[id] { return cached }
            guard visiting.insert(id).inserted, let entries = graph[id] else { return nil }
            defer { visiting.remove(id) }
            var deepest = 1
            var longest = 0
            var expanded = 0
            for entry in entries {
                var path = entry.nameBytes
                expanded += 1
                if let child = entry.subtree {
                    guard let below = dimensions(child, at: depth + 1) else { return nil }
                    deepest = max(deepest, below.depth + 1)
                    expanded += below.entries
                    if below.path > 0 { path += 1 + below.path }
                }
                longest = max(longest, path)
                guard deepest <= maximumDepth, longest <= maximumPathBytes, expanded <= maximumEntries else { return nil }
            }
            let result = Dimensions(depth: deepest, path: longest, entries: expanded)
            measured[id] = result
            return result
        }
        for tree in trees {
            guard dimensions(tree, at: 1) != nil else { throw PluginSourceFetchError.tooLarge }
        }
    }

    private static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
