import Foundation

struct GitOutput {
    let status: Int32
    let output: String
    let errorOutput: String

    var succeeded: Bool { status == 0 }
    var trimmedOutput: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    var firstErrorLine: String {
        errorOutput.split(separator: "\n").first.map(String.init) ?? "git exited with status \(status)"
    }
}

enum GitError: LocalizedError {
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command): "git \(command) took too long and was stopped"
        }
    }
}

enum Git {
    private static let executable = URL(filePath: "/usr/bin/git")

    // A menu bar app gets launchd's minimal PATH, so Homebrew credential helpers such as gh would not be found.
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }()

    static func run(_ arguments: [String], in directory: URL, timeout: Duration = .seconds(120)) async throws -> GitOutput {
        let outputURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let errorURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        defer { watchdog.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if process.terminationReason == .uncaughtSignal { throw GitError.timedOut(command: arguments.first ?? "") }
        return GitOutput(
            status: status,
            output: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            errorOutput: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }
}
