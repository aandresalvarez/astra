import Foundation
import Testing
import ASTRACore

@Suite("Process waits make independent progress", .serialized)
struct ProcessWaitExecutorTests {
    @Test("Long-lived waits cannot occupy the capacity needed by a short wait")
    func shortWaitRemainsIndependent() async {
        // This exceeds the utility pool capacity on both the CI runner and
        // the development machine. No child processes or CPU load are needed:
        // each wait holds a gate until the short operation has been observed.
        let result = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let count = 96
                let started = DispatchGroup()
                let finished = DispatchGroup()
                let release = DispatchSemaphore(value: 0)
                for _ in 0..<count {
                    started.enter()
                    finished.enter()
                    ProcessWaitExecutor.submit {
                        started.leave()
                        release.wait()
                        finished.leave()
                    }
                }
                // These deadlines only break a broken scheduler's hang; the
                // success condition is progress while every gate stays held.
                let allStarted = started.wait(timeout: .now() + 30) == .success
                let short = DispatchSemaphore(value: 0)
                if allStarted { ProcessWaitExecutor.submit { short.signal() } }
                let shortFinished = allStarted && short.wait(timeout: .now() + 30) == .success
                for _ in 0..<count { release.signal() }
                let allFinished = finished.wait(timeout: .now() + 30) == .success
                continuation.resume(returning: (allStarted, shortFinished, allFinished))
            }
        }
        #expect(result.0, "Long waits exhausted shared scheduling capacity")
        #expect(result.1, "The short wait could not progress until long waits were released")
        #expect(result.2, "A test waiter survived cleanup")
    }
}
