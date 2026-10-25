import Foundation

/// A remote monotonic reference, never a comparison of two wall clocks.
/// Adding the LOCAL allowance remaining after receiving this sample to the
/// earlier remote instant is conservative: transit can only shorten the job.
public enum RemoteWorkspaceJobClock {
    public struct Reference: Codable, Equatable, Sendable {
        public let bootID: String
        public let deadline: TimeInterval
        public init(bootID: String, deadline: TimeInterval) { self.bootID = bootID; self.deadline = deadline }
    }

    static let script = #"""
python3 - <<'ASTRA_CLOCK_PY'
import json, pathlib, subprocess, time
try:
    boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
except OSError:
    boot = subprocess.check_output(['sysctl', '-n', 'kern.boottime'], text=True).strip()
print(json.dumps({'astra_clock': 1, 'boot_id': boot, 'monotonic': time.monotonic()}))
ASTRA_CLOCK_PY
"""#

    static func sample(_ transport: RemoteWorkspaceJobTransport, connection: RemoteWorkspaceJobConnection) throws -> (bootID: String, monotonic: TimeInterval) {
        let result = transport.run(connection: connection, script: script, timeoutSeconds: 30)
        guard !result.timedOut, result.exitCode == 0, result.stdout.utf8.count < 8192,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              object["astra_clock"] as? Int == 1,
              let boot = object["boot_id"] as? String, !boot.isEmpty, boot.count < 4096,
              let clock = object["monotonic"] as? Double, clock.isFinite, clock > 0 else {
            throw RemoteWorkspaceJobError.invalidArgument("The SSH host's monotonic clock and boot identity could not be verified. No command was launched.")
        }
        return (boot, clock)
    }
}
