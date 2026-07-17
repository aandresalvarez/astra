import Darwin
import Foundation

public enum RunSupervisorExecutable {
    public static func run(arguments: [String]) throws {
        let descriptors = try descriptors(in: arguments)
        let bootstrapFD = descriptors.bootstrap
        let rootFD = descriptors.root
        guard bootstrapFD >= 3, rootFD >= 3, bootstrapFD != rootFD else {
            throw RunSupervisorError.invalidSchema
        }
        let frame = try RunSupervisorFrameIO.readFrame(
            from: bootstrapFD,
            maximumBytes: RunSupervisorProtocol.maximumBootstrapBytes
        )
        let payload = try RunSupervisorWireCoding.decode(RunSupervisorBootstrapPayload.self, from: frame)
        try RunSupervisorBootstrapValidator.validate(payload)
        let root = try RunSupervisorTrustedRoot(fileDescriptor: rootFD)
        close(rootFD)
        close(bootstrapFD)
        try detachFromBroker()
        _ = try RunSupervisorService(root: root).run(payload)
    }

    private static func descriptors(in arguments: [String]) throws -> (bootstrap: Int32, root: Int32) {
        guard arguments.count == 5 else { throw RunSupervisorError.invalidSchema }
        var values: [String: Int32] = [:]
        var index = 1
        while index < arguments.count {
            let name = arguments[index]
            guard name == "--bootstrap-fd" || name == "--root-fd",
                  values[name] == nil,
                  let value = Int32(arguments[index + 1]), value >= 0 else {
                throw RunSupervisorError.invalidSchema
            }
            values[name] = value
            index += 2
        }
        guard let bootstrap = values["--bootstrap-fd"], let root = values["--root-fd"] else {
            throw RunSupervisorError.invalidSchema
        }
        return (bootstrap, root)
    }

    private static func detachFromBroker() throws {
        if setsid() < 0, errno != EPERM {
            throw RunSupervisorError.systemCall("setsid", errno)
        }
        let nullFD = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0 else { throw RunSupervisorError.systemCall("open /dev/null", errno) }
        defer { close(nullFD) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard dup2(nullFD, descriptor) >= 0 else {
                throw RunSupervisorError.systemCall("dup2 detached stdio", errno)
            }
        }
    }
}
