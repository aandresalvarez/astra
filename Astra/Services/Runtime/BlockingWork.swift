import Foundation

/// Runs work that blocks its thread — a child process it waits on, a
/// directory walk — away from both the main actor and Swift's cooperative
/// pool. Blocking the main actor freezes the UI; blocking a pool thread can
/// starve every other task in the process, so neither is where `Process`
/// waits belong. A dispatch worker is.
///
/// This is the async boundary `MainActorProcessLaunchFitnessTests` asks
/// main-actor code to put in front of a `Process` launch.
enum BlockingWork {
    static func run<Value: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: work())
            }
        }
    }
}
