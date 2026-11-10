import Foundation
import CoreFoundation

/// Names the input that left a run's cleanup unproven, for the launch log
/// only. A provider CLI update that adds one field otherwise looks identical
/// to a run that used tools. Never evidence, and never read back to decide
/// anything: it reports field names and value kinds, not values.
enum RuntimeExecutionUncertaintyCause {
    static let limit = 6
    private static let fieldLimit = 24

    /// `label:type[shape]`, e.g.
    /// `unclassified:session.mcp_servers_loaded[servers{name:s,source:absent|s}]`.
    static func frame(_ label: String, _ frame: [String: Any]) -> String {
        let type = (frame["type"] as? String).map(name) ?? "untyped"
        let fields = (frame["data"] as? [String: Any]).map { shape([$0], depth: 3) } ?? ""
        return fields.isEmpty ? "\(label):\(type)" : "\(label):\(type)[\(fields)]"
    }

    /// Nested objects in braces; the kinds seen across a list's entries are
    /// joined by `|`: `s` string, `n` number, `b` boolean, `null`, `absent`.
    /// Bounded in depth and in fields per object (`+N` counts the rest).
    private static func shape(_ objects: [[String: Any]], depth: Int) -> String {
        let keys = Set(objects.flatMap(\.keys)).sorted()
        let shown = keys.prefix(fieldLimit).map { key -> String in
            let values = objects.compactMap { $0[key] }
            var kinds = Set<String>()
            var nested: [[String: Any]] = []
            if values.count < objects.count { kinds.insert("absent") }
            for value in values {
                if value is NSNull { kinds.insert("null") }
                else if value is String { kinds.insert("s") }
                else if let number = value as? NSNumber {
                    kinds.insert(CFGetTypeID(number) == CFBooleanGetTypeID() ? "b" : "n")
                } else if let object = value as? [String: Any] { nested.append(object) }
                else if let list = value as? [[String: Any]] { nested += list; if list.isEmpty { kinds.insert("[]") } }
                else if value is [Any] { kinds.insert("list") }
                else { kinds.insert("other") }
            }
            var text = name(key)
            if !nested.isEmpty { text += depth > 1 ? "{\(shape(nested, depth: depth - 1))}" : "{}" }
            if !kinds.isEmpty { text += ":" + kinds.sorted().joined(separator: "|") }
            return text
        }
        return (shown + (keys.count > fieldLimit ? ["+\(keys.count - fieldLimit)"] : [])).joined(separator: ",")
    }

    /// Some provider maps are keyed by data (a model, a path, a tool's own
    /// output). Only identifier-like keys are printed; anything else is `?`.
    private static func name(_ key: String) -> String {
        let allowed = key.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0))
        }
        return allowed && !key.isEmpty && key.count <= 48 ? key : "?"
    }
}
