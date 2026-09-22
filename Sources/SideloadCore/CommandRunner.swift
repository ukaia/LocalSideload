import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum CommandRunner {
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String] = [:],
                           directory: URL? = nil, allowFailure: Bool = false,
                           log: JobLog = { _ in }) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read while the child runs, so long Xcode output cannot fill the pipe.
        var collected = Data()
        var pending = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            collected.append(chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                if !line.isEmpty { log(line) }
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { log(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        let output = String(decoding: collected, as: UTF8.self)
        if process.terminationStatus != 0 && !allowFailure {
            let lines = output.split(separator: "\n")
            let useful = lines.filter { $0.localizedCaseInsensitiveContains("error:") }
            let detail = (useful.isEmpty ? Array(lines.suffix(12)) : Array(useful.suffix(8)))
                .joined(separator: "\n")
            throw SideloadError("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)).\n\(detail)")
        }
        return CommandResult(status: process.terminationStatus, output: output)
    }
}
