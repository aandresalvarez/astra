import ApplicationServices
import Foundation

// Also compiled directly into the standalone controller; never linked into ASTRA.
enum AXReadiness {
    static let names = ["AXRole", "AXTitle", "AXDescription", "AXIdentifier", "AXValue", "AXChildren"]

    struct Batch {
        let status: AXError
        let values: [Any]?
    }

    struct Result {
        let element: AXUIElement?
        let complete: Bool

        // Both standalone waits and input-to-ready polls use this gate.
        func isReady(present: Bool) -> Bool {
            complete && (element != nil) == present
        }
    }

    enum Attribute {
        case value(Any)
        case absent
        case unavailable
    }

    static func decode(_ raw: Any) -> Attribute {
        let reference = raw as CFTypeRef
        // Apple's multiple-read API also represents unsupported attributes as CFNull.
        // https://developer.apple.com/documentation/applicationservices/1462051-axuielementcopymultipleattribute
        if CFGetTypeID(reference) == CFNullGetTypeID() { return .absent }
        if CFGetTypeID(reference) == AXValueGetTypeID() {
            let value = unsafeBitCast(reference, to: AXValue.self)
            if AXValueGetType(value) == .axError {
                var error = AXError.success
                guard AXValueGetValue(value, .axError, &error) else { return .unavailable }
                return error == .attributeUnsupported || error == .noValue ? .absent : .unavailable
            }
        }
        return .value(raw)
    }

    static func text(_ raw: Any, allowNonText: Bool = false) -> (value: String?, complete: Bool) {
        switch decode(raw) {
        case .absent: return (nil, true)
        case .unavailable: return (nil, false)
        case .value(let value):
            if let string = value as? String { return (string, true) }
            // AXValue can legitimately be numeric, boolean or geometric.
            return (nil, allowNonText)
        }
    }

    static func children(_ raw: Any) -> (elements: [AXUIElement], complete: Bool) {
        switch decode(raw) {
        case .absent: return ([], true)
        case .unavailable: return ([], false)
        case .value(let value):
            guard let list = value as? [Any] else { return ([], false) }
            var elements: [AXUIElement] = []
            for child in list {
                let reference = child as CFTypeRef
                guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return ([], false) }
                elements.append(unsafeBitCast(reference, to: AXUIElement.self))
            }
            return (elements, true)
        }
    }

    static func read(_ element: AXUIElement) -> Batch {
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
        return Batch(status: status, values: values as? [Any])
    }

    static func match(_ list: [Any], role: String?, needle: String) -> (found: Bool, complete: Bool) {
        if needle.hasPrefix("role:") { return (role == String(needle.dropFirst(5)), true) }
        if needle.hasPrefix("scroll:") {
            guard role == "AXScrollArea" else { return (false, true) }
            let identifier = text(list[3])
            return (identifier.value == String(needle.dropFirst(7)), identifier.complete)
        }
        if needle.hasPrefix("id:") {
            let parts = needle.dropFirst(3).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return (false, false) }
            guard role == String(parts[0]) else { return (false, true) }
            let identifier = text(list[3])
            return (identifier.value == String(parts[1]), identifier.complete)
        }
        let indices: [Int], textNeedle: String
        if needle.hasPrefix("value:") {
            indices = [4]; textNeedle = String(needle.dropFirst(6))
        } else if needle.hasPrefix("content:") {
            indices = [1, 2, 4]; textNeedle = String(needle.dropFirst(8))
        } else if needle.hasPrefix("label:") {
            indices = [1, 2]; textNeedle = String(needle.dropFirst(6))
        } else {
            indices = [1, 2, 3, 4]; textNeedle = needle
        }
        let substring = textNeedle.hasPrefix("contains:")
        let target = substring ? String(textNeedle.dropFirst(9)) : textNeedle
        var complete = true
        for index in indices {
            let attribute = text(list[index], allowNonText: index == 4)
            if let value = attribute.value, substring ? value.contains(target) : value == target {
                return (true, true) // A positive witness does not need the other attributes.
            }
            complete = complete && attribute.complete
        }
        return (false, complete)
    }

    // One IPC per node, early positive exit. An unknown subtree or relevant
    // matching attribute cannot establish absence; the caller must poll again.
    static func find(_ root: AXUIElement, _ needle: String, scoped: Bool = true,
                     reader: (AXUIElement) -> Batch = AXReadiness.read) -> Result {
        if scoped && needle.contains("TaskRow_") {
            let sidebar = find(root, "scroll:TaskSidebar", reader: reader)
            guard let element = sidebar.element else { return sidebar }
            return find(element, needle, scoped: false, reader: reader)
        }
        var queue = [root], index = 0, complete = true
        while index < queue.count && index < 12_000 {
            let element = queue[index]; index += 1
            let batch = reader(element)
            guard batch.status == .success, let list = batch.values, list.count == names.count else {
                complete = false
                continue
            }
            let role = text(list[0])
            // Role is also needed to exclude global macOS menus reliably.
            guard role.complete else { complete = false; continue }
            if role.value == "AXMenuBar" { continue }
            let matched = match(list, role: role.value, needle: needle)
            if matched.found { return Result(element: element, complete: true) }
            let descendants = children(list[5])
            complete = complete && matched.complete && descendants.complete
            queue += descendants.elements
        }
        return Result(element: nil, complete: complete && index == queue.count)
    }
}
