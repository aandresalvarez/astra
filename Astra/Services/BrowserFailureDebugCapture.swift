import AppKit
import Foundation

enum BrowserFailureDebugCapture {
    static let headerName = "x-astra-browser-debug-capture"
    static let environmentVariable = "ASTRA_BROWSER_DEBUG_CAPTURE"

    struct Policy: Equatable {
        let isEnabled: Bool
        let source: String

        var scope: String {
            "failure_only"
        }
    }

    static func policy(
        for request: BrowserBridgeRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Policy {
        if let headerValue = request.headerValue(headerName),
           let enabled = boolValue(headerValue) {
            return Policy(isEnabled: enabled, source: "request_header")
        }

        if let envValue = environment[environmentVariable],
           let enabled = boolValue(envValue) {
            return Policy(isEnabled: enabled, source: "environment")
        }

        return Policy(isEnabled: false, source: "default")
    }

    static func shouldCapture(statusCode: Int, result: [String: Any]?) -> Bool {
        if statusCode >= 400 { return true }
        guard let result else { return false }
        if let ok = result["ok"], boolValue(ok) == false { return true }
        if (result["error"] as? String)?.isEmpty == false { return true }
        if result["loopWarning"] != nil { return true }
        if result["runGuard"] != nil { return true }
        return false
    }

    static func skippedCapture(
        policy: Policy,
        request: BrowserBridgeRequest,
        statusCode: Int,
        result: [String: Any]?,
        page: BrowserFlightPageSnapshot
    ) -> [String: Any] {
        [
            "enabled": false,
            "scope": policy.scope,
            "source": policy.source,
            "reason": "opt_in_required",
            "hint": "Set \(environmentVariable)=1 for astra-browser to attach failure-only screenshots, compact trees, and console/navigation/network events.",
            "trigger": triggerObject(request: request, statusCode: statusCode, result: result),
            "page": page.jsonObject,
            "privacy": privacyObject()
        ]
    }

    static func captureEnvelope(
        policy: Policy,
        request: BrowserBridgeRequest,
        statusCode: Int,
        result: [String: Any]?,
        page: BrowserFlightPageSnapshot
    ) -> [String: Any] {
        [
            "enabled": true,
            "scope": policy.scope,
            "source": policy.source,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "trigger": triggerObject(request: request, statusCode: statusCode, result: result),
            "page": page.jsonObject,
            "privacy": privacyObject()
        ]
    }

    static func compactSnapshotTree(from snapshot: [String: Any], limit: Int = 40) -> [String: Any] {
        let controls = snapshot["controls"] as? [[String: Any]] ?? []
        var object: [String: Any] = [
            "ok": true,
            "url": BrowserFlightPageSnapshot.redactedURLString(stringValue(snapshot["url"])),
            "title": String(stringValue(snapshot["title"]).prefix(160)),
            "controlCount": controls.count,
            "returnedControlCount": min(max(0, limit), controls.count),
            "controls": controls.prefix(max(0, limit)).map(compactControl)
        ]

        if let viewport = snapshot["viewport"] as? [String: Any] {
            object["viewport"] = viewport
        }
        if let focused = snapshot["focusedElement"] as? [String: Any] {
            object["focusedElement"] = compactControl(focused)
        }
        return object
    }

    static func compactAccessibilityTree(from snapshot: [String: Any], limit: Int = 80) -> [String: Any] {
        let nodes = snapshot["nodes"] as? [[String: Any]] ?? []
        return [
            "ok": boolValue(snapshot["ok"]),
            "url": BrowserFlightPageSnapshot.redactedURLString(stringValue(snapshot["url"])),
            "title": String(stringValue(snapshot["title"]).prefix(160)),
            "nodeCount": intValue(snapshot["nodeCount"]) ?? nodes.count,
            "returnedNodeCount": min(max(0, limit), nodes.count),
            "nodes": nodes.prefix(max(0, limit)).map(compactAccessibilityNode)
        ]
    }

    static func compactDebugEvents(from object: [String: Any], limit: Int = 30) -> [String: Any] {
        let consoleEvents = object["consoleEvents"] as? [[String: Any]] ?? []
        let navigationEvents = object["navigationEvents"] as? [[String: Any]] ?? []
        let networkEvents = object["networkEvents"] as? [[String: Any]] ?? []
        return [
            "ok": boolValue(object["ok"]),
            "url": BrowserFlightPageSnapshot.redactedURLString(stringValue(object["url"])),
            "title": String(stringValue(object["title"]).prefix(160)),
            "consoleEventCount": consoleEvents.count,
            "navigationEventCount": navigationEvents.count,
            "networkEventCount": networkEvents.count,
            "consoleEvents": consoleEvents.suffix(max(0, limit)).map(compactConsoleEvent),
            "navigationEvents": navigationEvents.suffix(max(0, limit)).map(compactNavigationEvent),
            "networkEvents": networkEvents.suffix(max(0, limit)).map(compactNetworkEvent)
        ]
    }

    static func screenshotObject(
        from image: NSImage,
        source: String,
        maxWidth: CGFloat = 480,
        compression: CGFloat = 0.55
    ) -> [String: Any]? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let scale = min(1, maxWidth / max(image.size.width, 1))
        let targetSize = NSSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: compression]
        ) else {
            return nil
        }

        return [
            "format": "jpeg",
            "source": source,
            "thumbnail": true,
            "width": Int(targetSize.width),
            "height": Int(targetSize.height),
            "bytes": data.count,
            "base64": data.base64EncodedString()
        ]
    }

    static func screenshotObject(
        fromBase64JPEG base64: String,
        source: String,
        maxWidth: CGFloat = 480
    ) -> [String: Any]? {
        guard let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else {
            return nil
        }
        return screenshotObject(from: image, source: source, maxWidth: maxWidth)
    }

    private static func triggerObject(
        request: BrowserBridgeRequest,
        statusCode: Int,
        result: [String: Any]?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "command": "\(request.method) \(request.path)",
            "method": request.method,
            "path": request.path,
            "statusCode": statusCode
        ]
        if let result {
            object["ok"] = boolValue(result["ok"])
            if let error = result["error"] as? String, !error.isEmpty {
                object["error"] = String(error.prefix(120))
            }
            if let loopWarning = result["loopWarning"] as? String, !loopWarning.isEmpty {
                object["loopWarning"] = String(loopWarning.prefix(180))
            }
        }
        return object
    }

    private static func privacyObject() -> [String: Any] {
        [
            "urlQueriesAndFragments": "redacted",
            "requestTextFields": "length_and_hash",
            "snapshotText": "length_and_hash",
            "accessibilityNames": "length_and_hash",
            "consoleMessages": "redacted_preview_length_and_hash",
            "screenshot": "thumbnail_only_when_opted_in"
        ]
    }

    private static func compactControl(_ control: [String: Any]) -> [String: Any] {
        var object: [String: Any] = [
            "tag": stringValue(control["tag"]),
            "role": stringValue(control["role"]),
            "type": stringValue(control["type"]),
            "disabled": boolValue(control["disabled"]),
            "actionable": boolValue(control["actionable"])
        ]

        for key in ["selector", "label", "name", "placeholder", "value", "testID"] {
            let text = stringValue(control[key])
            if !text.isEmpty {
                object[key] = compactText(text, includePreview: false)
            }
        }

        let href = stringValue(control["href"])
        if !href.isEmpty {
            object["href"] = BrowserFlightPageSnapshot.redactedURLString(href)
        }
        if let bounds = control["bounds"] as? [String: Any] {
            object["bounds"] = bounds
        }
        if let framePath = control["framePath"] as? [String], !framePath.isEmpty {
            object["framePath"] = compactText(framePath.joined(separator: " > "), includePreview: false)
        }
        if let shadowDepth = intValue(control["shadowDepth"]) {
            object["shadowDepth"] = shadowDepth
        }
        return object
    }

    private static func compactAccessibilityNode(_ node: [String: Any]) -> [String: Any] {
        var object: [String: Any] = [
            "nodeId": stringValue(node["nodeId"]),
            "backendDOMNodeId": stringValue(node["backendDOMNodeId"]),
            "ignored": boolValue(node["ignored"]),
            "role": accessibilityValue(node["role"])
        ]

        for key in ["name", "value", "description"] {
            let text = accessibilityValue(node[key])
            if !text.isEmpty {
                object[key] = compactText(text, includePreview: false)
            }
        }

        if let properties = node["properties"] as? [[String: Any]] {
            object["properties"] = properties.prefix(12).map { property in
                [
                    "name": stringValue(property["name"]),
                    "value": compactText(accessibilityValue(property["value"]), includePreview: false)
                ]
            }
        }
        return object
    }

    private static func compactConsoleEvent(_ event: [String: Any]) -> [String: Any] {
        var object: [String: Any] = [
            "level": stringValue(event["level"]),
            "message": compactText(redactURLs(in: stringValue(event["message"])), includePreview: true),
            "timestamp": stringValue(event["timestamp"])
        ]
        let source = stringValue(event["source"])
        if !source.isEmpty {
            object["source"] = BrowserFlightPageSnapshot.redactedURLString(source)
        }
        for key in ["line", "column"] {
            if let value = intValue(event[key]) {
                object[key] = value
            }
        }
        return object
    }

    private static func compactNavigationEvent(_ event: [String: Any]) -> [String: Any] {
        [
            "type": stringValue(event["type"]),
            "url": BrowserFlightPageSnapshot.redactedURLString(stringValue(event["url"])),
            "timestamp": stringValue(event["timestamp"])
        ]
    }

    private static func compactNetworkEvent(_ event: [String: Any]) -> [String: Any] {
        var object: [String: Any] = [
            "type": stringValue(event["type"]),
            "url": BrowserFlightPageSnapshot.redactedURLString(stringValue(event["url"])),
            "timestamp": stringValue(event["timestamp"])
        ]
        for key in ["method", "status", "elapsedMs"] {
            let value = event[key]
            if let int = intValue(value) {
                object[key] = int
            } else {
                let string = stringValue(value)
                if !string.isEmpty {
                    object[key] = string
                }
            }
        }
        let error = stringValue(event["error"])
        if !error.isEmpty {
            object["error"] = compactText(redactURLs(in: error), includePreview: true)
        }
        return object
    }

    private static func compactText(_ value: String, includePreview: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "length": value.count,
            "hash": stableHash(value)
        ]
        if includePreview {
            object["preview"] = String(value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(180))
        }
        return object
    }

    private static func accessibilityValue(_ value: Any?) -> String {
        if let object = value as? [String: Any] {
            return stringValue(object["value"])
        }
        return stringValue(value)
    }

    private static func redactURLs(in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s"')<>]+"#) else {
            return text
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var redacted = text
        for match in expression.matches(in: text, range: nsRange).reversed() {
            guard let range = Range(match.range, in: redacted) else { continue }
            let replacement = BrowserFlightPageSnapshot.redactedURLString(String(redacted[range]))
            redacted.replaceSubrange(range, with: replacement)
        }
        return redacted
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes", "y", "enabled", "failure", "failures", "always"].contains(
                string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
        return false
    }

    private static func boolValue(_ value: String) -> Bool? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "yes", "y", "enabled", "failure", "failures", "always"].contains(normalized) {
            return true
        }
        if ["0", "false", "no", "n", "disabled", "off"].contains(normalized) {
            return false
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return ""
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
