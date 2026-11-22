import Foundation
import Darwin
import os
import AstraObjCSupport

/// Reads the main thread's call stack from the watchdog's queue.
///
/// `MainThreadPhase` names the instrumented scope a stall happened in, and in
/// eight days of production logs 1,834 of 1,884 stall reports carried
/// `phase=none`: the main thread was somewhere nothing marks. A marker can only
/// name code somebody thought to mark, so the report could say that ASTRA froze
/// for 198 minutes and could not say where.
///
/// The stack needs no marks. The watchdog stops the main thread for the length
/// of a frame-pointer walk, a few dozen kernel calls, and lets it go. The line
/// it writes holds addresses as `image+offset`, which is what `atos` needs to
/// name them against the build's dSYM after the process is gone. Names are not
/// resolved here: a Swift symbol is long enough for the log's token redaction
/// to remove it, and an offset is not.
enum MainThreadStackSampler {
    /// Deep enough to reach from a SwiftUI layout pass back to the app frame
    /// that started it.
    static let maximumFrames = 128
    /// `PerformanceTelemetryFields.safeValue` cuts a value at this length.
    static let fieldLength = 96
    /// Innermost frames reported with their image: what the thread was doing.
    static let topFieldCount = 2
    /// Frames from this binary, reported as bare offsets: who asked for it.
    static let appFieldCount = 2

    struct Frame: Equatable {
        let image: String
        let offset: UInt
        let isApp: Bool
    }

    private static let mainThreadPort = OSAllocatedUnfairLock<UInt32>(initialState: 0)

    /// Records which thread is the main one. Call on the main thread.
    static func install() {
        guard Thread.isMainThread else { return }
        let port = AstraCurrentThreadPort()
        mainThreadPort.withLock { $0 = port }
    }

    /// The main thread's return addresses, innermost first. Empty until
    /// `install()` has run, and when called on the main thread itself.
    static func captureMainThread() -> [UInt] {
        capture(thread: mainThreadPort.withLock { $0 })
    }

    static func capture(thread: UInt32) -> [UInt] {
        guard thread != 0 else { return [] }
        // Allocated before the thread is stopped: the walk must not.
        var frames = [UInt](repeating: 0, count: maximumFrames)
        var top = AstraThreadStackTop()
        let count = frames.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return Int(AstraCaptureThreadStack(thread, base, Int32(buffer.count), &top))
        }
        var stack = Array(frames.prefix(max(0, min(count, maximumFrames))))
        if let caller = missedLeafCaller(
            stack: stack, linkRegister: top.linkRegister, firstFrameReturn: top.firstFrameReturnAddress
        ) {
            stack.insert(caller, at: 1)
        }
        return Array(stack.prefix(maximumFrames))
    }

    /// The caller a frame-pointer walk skips when the thread is stopped in a
    /// function that set up no frame, which is where a blocked thread usually
    /// is: a system-call stub. The frame pointer then still belongs to the
    /// caller, so the walk's second address is the caller's caller.
    ///
    /// The link register is that caller when the innermost function is such
    /// a leaf, and a leftover otherwise: the function's own return address,
    /// which the walk already has, or the return point of the last call it
    /// made, which lies inside the function itself. So it is a missed caller
    /// only when it is not the return address of the first frame record and
    /// belongs to a different function than the innermost one.
    ///
    /// It is compared with the first frame record, not with the stack's second
    /// address: when the innermost function is async, the functions awaiting
    /// it sit between the two, and its own return address would look missed.
    /// Where the loader cannot name either function, nothing is added: a stack
    /// one frame short is better than one with a frame that was never there.
    static func missedLeafCaller(stack: [UInt], linkRegister: UInt, firstFrameReturn: UInt) -> UInt? {
        guard linkRegister != 0, linkRegister != firstFrameReturn, let innermost = stack.first else { return nil }
        guard let innermostFunction = functionStart(of: innermost),
              let returnFunction = functionStart(of: linkRegister),
              innermostFunction != returnFunction else { return nil }
        return linkRegister
    }

    private static func functionStart(of address: UInt) -> UnsafeMutableRawPointer? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return nil }
        return info.dli_saddr
    }

    /// Resolves each address to the image that holds it. Runs after the thread
    /// has been resumed: `dladdr` takes the loader's lock.
    static func frames(for addresses: [UInt], appImageBase: UnsafeRawPointer = #dsohandle) -> [Frame] {
        addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else {
                return Frame(image: "unknown", offset: address, isApp: false)
            }
            let path = info.dli_fname.map { String(cString: $0) } ?? "unknown"
            return Frame(
                image: imageName(path),
                offset: address &- UInt(bitPattern: base),
                isApp: UnsafeRawPointer(base) == appImageBase
            )
        }
    }

    /// `libsystem_kernel.dylib` as `system_kernel`: the prefix and suffix say
    /// nothing, and every character saved is another frame on the line.
    static func imageName(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".dylib") { name.removeLast(6) }
        if name.hasPrefix("lib"), name.count > 3 { name.removeFirst(3) }
        return name.isEmpty ? "unknown" : name
    }

    /// The fields of one `main_thread_stall_stack` line.
    ///
    /// `t0…` hold the innermost frames with their image. `a0…` hold the frames
    /// that belong to this binary, as offsets only, so a stall deep inside
    /// SwiftUI still shows the app code that led there. Both run innermost
    /// first and stop when their fields are full.
    static func telemetryFields(for frames: [Frame], isCurrent: Bool) -> [String: String] {
        var fields = [
            "frames": String(frames.count),
            "app_frames": String(frames.filter(\.isApp).count),
            "current": isCurrent ? "true" : "false"
        ]
        let top = frames.map { "\($0.image)+0x\(String($0.offset, radix: 16))" }
        for (index, value) in chunks(top, count: topFieldCount).enumerated() {
            fields["t\(index)"] = value
        }
        let app = frames.filter(\.isApp).map { "0x\(String($0.offset, radix: 16))" }
        for (index, value) in chunks(app, count: appFieldCount).enumerated() {
            fields["a\(index)"] = value
        }
        return fields
    }

    /// Packs tokens into at most `count` comma-joined values of `fieldLength`
    /// characters, never splitting a token.
    static func chunks(_ tokens: [String], count: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for token in tokens {
            guard token.count <= fieldLength else { continue }
            if current.isEmpty {
                current = token
            } else if current.count + 1 + token.count <= fieldLength {
                current += "," + token
            } else {
                result.append(current)
                guard result.count < count else { return result }
                current = token
            }
        }
        if !current.isEmpty, result.count < count { result.append(current) }
        return result
    }
}
