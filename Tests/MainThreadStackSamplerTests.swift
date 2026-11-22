import Foundation
import Testing
import ASTRALogging
import AstraObjCSupport
@testable import ASTRA

/// The sampler stops another thread to read its stack, so the things worth
/// pinning are that it reads a real one, that it always lets the thread go,
/// and that what it writes survives the log's own redaction.
@Suite("Main-thread stack sampler")
struct MainThreadStackSamplerTests {
    /// A thread blocked in `read(2)` on a pipe nobody has written to, called
    /// straight from a function this binary defines. The system-call stub sets
    /// up no frame, so the thread is stopped exactly where a stalled one
    /// usually is.
    private final class ParkedThread: @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private let finished = DispatchSemaphore(value: 0)
        private var descriptors: [Int32] = [-1, -1]
        private(set) var port: UInt32 = 0

        func start() -> Bool {
            guard pipe(&descriptors) == 0 else { return false }
            let thread = Thread { [self] in
                port = AstraCurrentThreadPort()
                ready.signal()
                parkInRead(descriptors[0])
                finished.signal()
            }
            thread.start()
            ready.wait()
            return true
        }

        @inline(never)
        private func parkInRead(_ descriptor: Int32) {
            var byte: UInt8 = 0
            _ = read(descriptor, &byte, 1)
        }

        /// Returns whether the thread ran to its end after being released.
        func release() -> Bool {
            var byte: UInt8 = 1
            _ = write(descriptors[1], &byte, 1)
            let ended = finished.wait(timeout: .now() + 5) == .success
            close(descriptors[0])
            close(descriptors[1])
            return ended
        }
    }

    /// The thread's stack once it is inside the system call: the innermost
    /// frame is then in the kernel's stub library. Sampled again rather than
    /// slept for, so a slow machine only costs more samples.
    private func stackInsideSystemCall(of parked: ParkedThread) -> [UInt] {
        for _ in 0..<500 {
            let addresses = MainThreadStackSampler.capture(thread: parked.port)
            if MainThreadStackSampler.frames(for: Array(addresses.prefix(1))).first?.image == "system_kernel" {
                return addresses
            }
            usleep(2_000)
        }
        return []
    }

    private func functionName(at address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname else { return "" }
        return String(cString: name)
    }

    @Test("A parked thread's stack is read from another thread, and the thread runs on")
    func parkedThreadStackIsCaptured() throws {
        let parked = ParkedThread()
        try #require(parked.start())

        let addresses = stackInsideSystemCall(of: parked)
        let frames = MainThreadStackSampler.frames(for: addresses)

        #expect(addresses.count >= 3)
        #expect(addresses.allSatisfy { $0 != 0 })
        // It is waiting inside code this binary defines.
        #expect(frames.contains { $0.isApp })
        #expect(frames.contains { !$0.isApp })
        // Stopped, read, and let go: a sampler that left it suspended would
        // freeze the app it is diagnosing.
        #expect(parked.release())
    }

    /// The stub the thread is stopped in has no frame, so the frame pointer
    /// still belongs to `parkInRead` and a walk of frame pointers alone goes
    /// from the stub to `parkInRead`'s caller. The function that made the
    /// blocking call is the one a stall report most needs.
    @Test("The function that made the blocking call is in the stack")
    func immediateCallerOfASystemCallIsKept() throws {
        let parked = ParkedThread()
        try #require(parked.start())

        let addresses = stackInsideSystemCall(of: parked)
        let names = addresses.prefix(3).map(functionName(at:))

        #expect(names.count == 3)
        #expect(names.dropFirst().first?.contains("parkInRead") == true, "innermost functions: \(names)")
        #expect(parked.release())
    }

    @Test("A leftover return address is not mistaken for a missed caller")
    func leafReturnIsOnlyUsedWhenItNamesAnotherFunction() throws {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        let first = UInt(bitPattern: try #require(dlsym(handle, "getpid")))
        let second = UInt(bitPattern: try #require(dlsym(handle, "strlen")))
        let third = UInt(bitPattern: try #require(dlsym(handle, "malloc")))

        // Stopped in a leaf: the return address names the caller the walk skipped.
        #expect(MainThreadStackSampler.missedLeafCaller(stack: [first, third], leafReturn: second + 4) == second + 4)
        // The innermost function has a frame and has not called anything yet:
        // the walk already holds its return address.
        #expect(MainThreadStackSampler.missedLeafCaller(stack: [first, second + 4], leafReturn: second + 4) == nil)
        // It has a frame and has made a call: the leftover points back into it.
        #expect(MainThreadStackSampler.missedLeafCaller(stack: [first + 4, third], leafReturn: first + 8) == nil)
        // Nothing captured, or nowhere the loader knows.
        #expect(MainThreadStackSampler.missedLeafCaller(stack: [first, third], leafReturn: 0) == nil)
        #expect(MainThreadStackSampler.missedLeafCaller(stack: [], leafReturn: second) == nil)
        #expect(MainThreadStackSampler.missedLeafCaller(stack: [first, third], leafReturn: 16) == nil)
    }

    @Test("A thread is never asked to stop itself")
    func ownThreadIsRefused() {
        #expect(MainThreadStackSampler.capture(thread: AstraCurrentThreadPort()).isEmpty)
        #expect(MainThreadStackSampler.capture(thread: 0).isEmpty)
    }

    @Test("Image names drop what every one of them shares")
    func imageNamesAreShortened() {
        #expect(MainThreadStackSampler.imageName("/usr/lib/system/libsystem_kernel.dylib") == "system_kernel")
        #expect(MainThreadStackSampler.imageName("/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI") == "SwiftUI")
        #expect(MainThreadStackSampler.imageName("") == "unknown")
    }

    @Test("Tokens are packed whole into a bounded number of bounded fields")
    func chunksNeverSplitATokenOrExceedTheBudget() {
        let tokens = (0..<40).map { "SwiftUI+0x1a2b\($0)" }
        let chunks = MainThreadStackSampler.chunks(tokens, count: 2)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count <= MainThreadStackSampler.fieldLength })
        let packed = chunks.flatMap { $0.split(separator: ",").map(String.init) }
        #expect(packed == Array(tokens.prefix(packed.count)))
        #expect(MainThreadStackSampler.chunks([], count: 2).isEmpty)
    }

    @Test("A stack line reaches the log intact")
    func stackFieldsSurviveSanitizing() {
        // The deepest stack the sampler reports, in the longest images.
        // Typed step by step: as one expression this took CI's compiler past
        // its type-checking limit.
        let firstOffset: UInt = 0x1_2345_6789
        var frames: [MainThreadStackSampler.Frame] = []
        for index in 0..<MainThreadStackSampler.maximumFrames {
            let isApp: Bool = index % 3 == 0
            let image: String = isApp ? "ASTRA" : "AttributeGraph"
            let offset: UInt = firstOffset + UInt(index)
            frames.append(MainThreadStackSampler.Frame(image: image, offset: offset, isApp: isApp))
        }
        let fields: [String: String] = MainThreadStackSampler.telemetryFields(for: frames, isCurrent: true)

        #expect(fields["frames"] == String(MainThreadStackSampler.maximumFrames))
        #expect(fields["t0"]?.hasPrefix("ASTRA+0x123456789,AttributeGraph+0x12345678a") == true)
        #expect(fields["a0"]?.hasPrefix("0x123456789,0x12345678c") == true)
        for (key, value) in fields {
            // What `PerformanceTelemetry.log` does to a value, then what the
            // logger does to the line.
            #expect(PerformanceTelemetryFields.safeValue(value) == value, "\(key) was cut or rewritten")
            #expect(LogSanitizer.sanitize(value) == value, "\(key) was redacted")
        }
        var parts: [String] = ["event=main_thread_stall_stack", "launch_age_ms=123456789.12"]
        for key in fields.keys.sorted() {
            parts.append(key + "=" + (fields[key] ?? ""))
        }
        let line: String = parts.joined(separator: " ")
        #expect(line.count <= LogSanitizer.maxMessageLength)
        #expect(LogSanitizer.sanitize(line) == line)
    }
}
