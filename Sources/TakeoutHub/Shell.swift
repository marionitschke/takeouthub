import Foundation

/// Runs command line tools. An app doesn't inherit the shell's PATH, so tools are always called by
/// absolute path and `environment` sets up the rest. All calls are synchronous; never use them on the
/// main thread.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
        var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "de_DE.UTF-8",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = current[key] { env[key] = value }
        }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Waits for the process and returns its output. `includeErrors: false` drops stderr, e.g. when stdout
    /// holds a value that an error message must not corrupt.
    static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                    includeErrors: Bool = true) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = includeErrors ? output : FileHandle.nullDevice
        let inputPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Reports every output line (stdout and stderr) as it arrives and returns the exit code. `started`
    /// receives the running process, e.g. to stop it.
    static func stream(_ executable: String, _ arguments: [String], environment extra: [String: String],
                       started: (Process) -> Void = { _ in }, onLine: (String) -> Void) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(extra)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            onLine("Start fehlgeschlagen: \(error.localizedDescription)")
            return -1
        }
        started(process)
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                onLine(line)
            }
        }
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
