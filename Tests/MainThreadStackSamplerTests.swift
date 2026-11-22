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
    /// A thread parked in a function this binary defines.
    private final class ParkedThread: @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)
        private let finished = DispatchSemaphore(value: 0)
        private(set) var port: UInt32 = 0

        func start() {
            let thread = Thread { [self] in
                port = AstraCurrentThreadPort()
                ready.signal()
                park()
                finished.signal()
            }
            thread.start()
            ready.wait()
        }

        @inline(never)
        private func park() {
            gate.wait()
        }

        /// Returns whether the thread ran to its end after being released.
        func release() -> Bool {
            gate.signal()
            return finished.wait(timeout: .now() + 5) == .success
        }
    }

    @Test("A parked thread's stack is read from another thread, and the thread runs on")
    func parkedThreadStackIsCaptured() {
        let parked = ParkedThread()
        parked.start()
        // Let it reach the wait; the stack is the same either side of it.
        Thread.sleep(forTimeInterval: 0.05)

        let addresses = MainThreadStackSampler.capture(thread: parked.port)
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
