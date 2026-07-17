import Darwin
import Foundation
import RunSupervisorSupport

guard CommandLine.arguments.count == 3 ||
      (CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--hold-after-launch") else {
    exit(64)
}
let rootPath = CommandLine.arguments[1]
let supervisorPath = CommandLine.arguments[2]
let holdAfterLaunch = CommandLine.arguments.count == 4
let rootFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
guard rootFD >= 0 else { exit(65) }
defer { close(rootFD) }
let inheritedRootFD = fcntl(rootFD, F_DUPFD_CLOEXEC, 64)
guard inheritedRootFD >= 0 else { exit(65) }
defer { close(inheritedRootFD) }

var bootstrapPipe = [Int32](repeating: -1, count: 2)
guard pipe(&bootstrapPipe) == 0 else { exit(66) }
defer {
    if bootstrapPipe[0] >= 0 { close(bootstrapPipe[0]) }
    if bootstrapPipe[1] >= 0 { close(bootstrapPipe[1]) }
}

let frame: Data
do {
    frame = try RunSupervisorFrameIO.readFrame(
        from: STDIN_FILENO,
        maximumBytes: RunSupervisorProtocol.maximumBootstrapBytes
    )
} catch {
    exit(67)
}

var actions: posix_spawn_file_actions_t? = nil
guard posix_spawn_file_actions_init(&actions) == 0 else { exit(68) }
defer { posix_spawn_file_actions_destroy(&actions) }
guard posix_spawn_file_actions_adddup2(&actions, bootstrapPipe[0], 3) == 0,
      posix_spawn_file_actions_adddup2(&actions, inheritedRootFD, 4) == 0,
      posix_spawn_file_actions_addclose(&actions, bootstrapPipe[1]) == 0 else {
    exit(69)
}

let argvStrings = [supervisorPath, "--bootstrap-fd", "3", "--root-fd", "4"]
var argv = argvStrings.map { $0.withCString(strdup) } + [nil]
var env = ProcessInfo.processInfo.environment
    .map { "\($0.key)=\($0.value)" }
    .sorted()
    .map { $0.withCString(strdup) } + [nil]
defer {
    argv.forEach { if let pointer = $0 { free(pointer) } }
    env.forEach { if let pointer = $0 { free(pointer) } }
}
var pid: pid_t = 0
let result = supervisorPath.withCString { executable in
    argv.withUnsafeMutableBufferPointer { argvBuffer in
        env.withUnsafeMutableBufferPointer { envBuffer in
            posix_spawn(&pid, executable, &actions, nil, argvBuffer.baseAddress, envBuffer.baseAddress)
        }
    }
}
guard result == 0 else { exit(70) }
close(bootstrapPipe[0]); bootstrapPipe[0] = -1
do {
    try RunSupervisorFrameIO.writeFrame(
        frame,
        to: bootstrapPipe[1],
        maximumBytes: RunSupervisorProtocol.maximumBootstrapBytes
    )
} catch {
    kill(pid, SIGKILL)
    exit(71)
}
close(bootstrapPipe[1]); bootstrapPipe[1] = -1
FileHandle.standardOutput.write(Data("\(pid)\n".utf8))
if holdAfterLaunch {
    while true { pause() }
}
exit(0)
