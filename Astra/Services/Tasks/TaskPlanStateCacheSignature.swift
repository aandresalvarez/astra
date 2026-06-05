import Foundation

struct TaskPlanStateCacheSignature: Equatable {
    static let empty = TaskPlanStateCacheSignature(
        taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        status: .draft,
        planEventCount: 0,
        planEventFingerprint: 0,
        runCount: 0,
        runFingerprint: 0
    )

    let taskID: UUID
    let status: TaskStatus
    let planEventCount: Int
    let planEventFingerprint: UInt64
    let runCount: Int
    let runFingerprint: UInt64

    init(task: AgentTask) {
        var eventAccumulator = FingerprintAccumulator()
        var planEventCount = 0
        for event in task.events {
            guard let eventCode = TaskPlanService.stateMutationCode(for: event.type) else {
                continue
            }
            eventAccumulator.include(planEventCount)
            planEventCount += 1
            eventAccumulator.include(eventCode)
            eventAccumulator.include(event.id)
            eventAccumulator.include(event.timestamp)
            eventAccumulator.include(event.payload.utf8.count)
            eventAccumulator.includeBoundedSample(event.payload)
        }

        var runAccumulator = FingerprintAccumulator()
        for (index, run) in task.runs.enumerated() {
            runAccumulator.include(index)
            runAccumulator.include(run.id)
            runAccumulator.include(Self.code(for: run.status))
            runAccumulator.include(run.startedAt)
            runAccumulator.include(run.completedAt)
            runAccumulator.include(run.output.utf8.count)
            if let protocolOutputFingerprint = Self.protocolOutputFingerprint(for: run.output) {
                runAccumulator.include(1)
                runAccumulator.include(protocolOutputFingerprint)
            } else {
                runAccumulator.include(0)
            }
        }

        self.init(
            taskID: task.id,
            status: task.status,
            planEventCount: planEventCount,
            planEventFingerprint: eventAccumulator.value,
            runCount: task.runs.count,
            runFingerprint: runAccumulator.value
        )
    }

    private init(
        taskID: UUID,
        status: TaskStatus,
        planEventCount: Int,
        planEventFingerprint: UInt64,
        runCount: Int,
        runFingerprint: UInt64
    ) {
        self.taskID = taskID
        self.status = status
        self.planEventCount = planEventCount
        self.planEventFingerprint = planEventFingerprint
        self.runCount = runCount
        self.runFingerprint = runFingerprint
    }

    private static func code(for status: RunStatus) -> Int {
        switch status {
        case .running: 0
        case .completed: 1
        case .failed: 2
        case .cancelled: 3
        case .timeout: 4
        case .budgetExceeded: 5
        }
    }

    private static func protocolOutputFingerprint(for output: String) -> UInt64? {
        guard var markerRange = output.range(of: "ASTRA_EVENT") else { return nil }
        var accumulator = FingerprintAccumulator()
        while true {
            let lineStart = output[..<markerRange.lowerBound].lastIndex(of: "\n").map { output.index(after: $0) } ?? output.startIndex
            let lineEnd = output[markerRange.upperBound...].firstIndex(of: "\n") ?? output.endIndex
            accumulator.include(output.distance(from: lineStart, to: lineEnd))
            accumulator.includeBoundedSample(output[lineStart..<lineEnd])

            guard let next = output[markerRange.upperBound...].range(of: "ASTRA_EVENT") else {
                break
            }
            markerRange = next
        }
        return accumulator.value
    }
}

private struct FingerprintAccumulator {
    private static let offset: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    private(set) var value = offset

    mutating func include(_ value: UInt64) {
        self.value ^= value
        self.value &*= Self.prime
    }

    mutating func include(_ value: Int) {
        include(UInt64(bitPattern: Int64(value)))
    }

    mutating func include(_ uuid: UUID) {
        var bytes = uuid.uuid
        withUnsafeBytes(of: &bytes) { buffer in
            for byte in buffer {
                include(UInt64(byte))
            }
        }
    }

    mutating func include(_ date: Date?) {
        include(date?.timeIntervalSinceReferenceDate.bitPattern ?? 0)
    }

    mutating func includeBoundedSample<S: StringProtocol>(_ value: S, edgeByteLimit: Int = 128) {
        let text = String(value)
        let utf8 = text.utf8
        include(utf8.count)

        var prefixCount = 0
        for byte in utf8 {
            include(UInt64(byte))
            prefixCount += 1
            if prefixCount >= edgeByteLimit { break }
        }

        guard utf8.count > edgeByteLimit else { return }

        var suffixBytes: [UInt8] = []
        suffixBytes.reserveCapacity(edgeByteLimit)
        for byte in utf8.reversed() {
            suffixBytes.append(byte)
            if suffixBytes.count >= edgeByteLimit { break }
        }
        include(suffixBytes.count)
        for byte in suffixBytes.reversed() {
            include(UInt64(byte))
        }
    }
}
