// External accessibility controller; no app instrumentation or PR 1 required.
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func nodes(_ root: AXUIElement) -> [AXUIElement] {
    var output: [AXUIElement] = [], queue = [root], index = 0
    while index < queue.count && index < 12_000 {
        let element = queue[index]; index += 1
        output.append(element)
        // Do not enumerate macOS's global menus/recent documents. They are not
        // benchmark content and make every poll needlessly expensive.
        queue += (attribute(element, "AXChildren") as? [AXUIElement] ?? []).filter { string($0, "AXRole") != "AXMenuBar" }
    }
    return output
}
func find(_ root: AXUIElement, _ needle: String, scoped: Bool = true) -> AXReadiness.Result {
    AXReadiness.find(root, needle, scoped: scoped)
}
func emit(_ value: Any) throws {
    print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
}
@main
struct DevScaleAX {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let pid = Int32(args[1]) else { fail("PID and command required") }
        // Popen returns before LaunchServices has registered the GUI process.
        let registrationDeadline = Date().addingTimeInterval(30)
        var registeredApp: NSRunningApplication?
        repeat {
            if let candidate = NSRunningApplication(processIdentifier: pid),
               candidate.bundleIdentifier?.hasPrefix("com.coral.ASTRA.dev.scalebench.") == true {
                registeredApp = candidate; break
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < registrationDeadline
        guard let app = registeredApp else {
            fail("Only a uniquely identified synthetic benchmark app may be controlled")
        }
        guard AXIsProcessTrusted() else { fail("Accessibility permission required for the invoking terminal") }
        // Direct executable launches may not present their first window until
        // activated. Request presentation only after the owned-app guard.
        if args[2] == "wait" { app.activate() }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 2)
        if args[2] == "dump" {
            try emit(nodes(root).map { element -> [String: String] in
                Dictionary(uniqueKeysWithValues: ["AXRole", "AXTitle", "AXDescription", "AXIdentifier", "AXValue"].map { ($0, String(string(element, $0).prefix(160))) })
            })
        } else if args[2] == "actions" {
            guard args.count == 4, let target = find(root, args[3]).element else { fail("actions target missing") }
            var actions: CFArray?
            AXUIElementCopyActionNames(target, &actions)
            try emit(actions as? [String] ?? [])
        } else if ["wait", "click", "right-click", "menu", "press"].contains(args[2]) {
            let click = args[2] != "wait"
            guard args.count == (click ? 6 : 5) else { fail("PID click TARGET READY present|absent or PID wait READY present|absent") }
            let ready = args[click ? 4 : 3]
            let present = args[click ? 5 : 4] == "present"
            if click {
                var before = find(root, ready)
                let initialDeadline = Date().addingTimeInterval(30)
                while !before.complete && Date() < initialDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                    before = find(root, ready)
                }
                guard before.complete else { fail("Could not verify the initial ready condition") }
                guard (before.element != nil) != present else { fail("Ready condition already true; refusing stale latency") }
                guard var target = find(root, args[3]).element else { fail("Target missing: \(args[3])") }
                app.activate()
                let focusDeadline = Date().addingTimeInterval(5)
                while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < focusDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { fail("Benchmark app could not acquire focus; no input sent") }
                // A ready row can exist while its disclosure animation is still moving
                // neighboring targets. Resolve fresh geometry until it stops moving;
                // this setup wait is outside the input-to-ready clock.
                var position = CGPoint.zero, size = CGSize.zero, stable = 0
                let geometryDeadline = Date().addingTimeInterval(15)
                while stable < 3 && Date() < geometryDeadline {
                    guard let fresh = find(root, args[3]).element,
                          let p = attribute(fresh, "AXPosition"), let s = attribute(fresh, "AXSize"),
                          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else {
                        stable = 0
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    var nextPosition = CGPoint.zero, nextSize = CGSize.zero
                    AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &nextPosition)
                    AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &nextSize)
                    stable = nextPosition == position && nextSize == size ? stable + 1 : 0
                    position = nextPosition; size = nextSize; target = fresh
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard stable == 3, size.width > 0, size.height > 0,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { fail("Target did not stabilize; no input sent") }
                let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
                let start = DispatchTime.now().uptimeNanoseconds
                if ["menu", "press"].contains(args[2]) {
                    // AppKit may keep the synchronous AX call pending while tracking
                    // the menu. A timeout is admissible only if the ready item appears.
                    AXUIElementSetMessagingTimeout(target, 0.2)
                    let result = AXUIElementPerformAction(target, (args[2] == "menu" ? "AXShowMenu" : "AXPress") as CFString)
                    guard result == .success || result == .cannotComplete else { fail("AXShowMenu failed: \(result.rawValue)") }
                } else {
                    let right = args[2] == "right-click"
                    FileHandle.standardError.write(Data("Input \(args[3]) at \(point.x),\(point.y)\n".utf8))
                    CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
                    Thread.sleep(forTimeInterval: 0.05)
                    CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
                }
                var polls = 0
                while Double(DispatchTime.now().uptimeNanoseconds - start) < 60_000_000_000 {
                    polls += 1
                    let probeStart = DispatchTime.now().uptimeNanoseconds
                    let observed = find(root, ready)
                    if observed.isReady(present: present) {
                        let finish = DispatchTime.now().uptimeNanoseconds
                        var result: [String: Any] = ["target": args[3], "ready": ready, "present": present,
                            "last_ready_probe_ms": Double(finish - probeStart) / 1_000_000, "polls": polls]
                        let key = args[2] == "menu" ? "menu_action_to_ax_ready_ms" : (args[2] == "press" ? "press_action_to_ax_ready_ms" : "click_to_ax_ready_ms")
                        result[key] = Double(finish - start) / 1_000_000
                        try emit(result); exit(0)
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                fail("Ready condition timed out")
            } else {
                let start = DispatchTime.now().uptimeNanoseconds
                while Double(DispatchTime.now().uptimeNanoseconds - start) < 120_000_000_000 {
                    let observed = find(root, ready)
                    if observed.isReady(present: present) {
                        try emit(["wait_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000]); exit(0)
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                fail("Wait timed out")
            }
        } else if args[2] == "set" {
            guard args.count == 5, let target = find(root, args[3]).element else { fail("set target missing") }
            guard AXUIElementSetAttributeValue(target, "AXValue" as CFString, args[4] as CFString) == .success else { fail("set failed") }
            try emit(["updated": true])
        } else { fail("unknown command") }
    }
}
