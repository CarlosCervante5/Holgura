import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { status == 0 }
}

public enum ShellError: LocalizedError {
    case notFound(String)
    case forbidden(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notFound(let tool): return "No se encontró «\(tool)» en el sistema."
        case .forbidden(let tool): return "«\(tool)» no está permitido."
        case .timedOut: return "El comando tardó demasiado y se canceló."
        }
    }
}

/// Ejecuta herramientas de línea de comandos del usuario. Nunca usa sudo ni pide contraseña.
public enum ShellRunner {
    public static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            home + "/.docker/bin", "/Applications/Docker.app/Contents/Resources/bin",
            home + "/.local/bin", "/opt/local/bin",
        ]
    }

    private static let forbidden: Set<String> = ["sudo", "su", "doas", "osascript", "rm", "security"]

    public static func locate(_ tool: String) -> URL? {
        for dir in searchPaths {
            let path = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    public static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        guard !forbidden.contains(tool) else { throw ShellError.forbidden(tool) }
        guard let executable = locate(tool) else { throw ShellError.notFound(tool) }
        return try await run(executable: executable, arguments, timeout: timeout)
    }

    public static func run(executable: URL, _ arguments: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        guard !forbidden.contains(executable.lastPathComponent) else {
            throw ShellError.forbidden(executable.lastPathComponent)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        env.removeValue(forKey: "SUDO_ASKPASS")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShellResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    var timedOut = false
                    let timer = DispatchWorkItem {
                        if process.isRunning { timedOut = true; process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                    var outData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    timer.cancel()
                    if timedOut {
                        continuation.resume(throwing: ShellError.timedOut)
                        return
                    }
                    continuation.resume(returning: ShellResult(
                        status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
