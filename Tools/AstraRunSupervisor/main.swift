import Foundation
import RunSupervisorSupport

do {
    try RunSupervisorExecutable.run(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("astra-run-supervisor: \(error)\n".utf8))
    exit(1)
}
