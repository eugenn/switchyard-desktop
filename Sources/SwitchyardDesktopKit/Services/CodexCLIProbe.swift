import Foundation

/// Reads the installed Codex CLI version for the setup step's `Codex CLI` row.
///
/// Purely informational: discovery itself never depends on the version string,
/// so a probe that fails simply leaves the row without one.
package enum CodexCLIProbe {
    package static func version() -> String? {
        guard let executable = LaunchEnvironment.locate(CodexModelDiscovery.executableName) else {
            return nil
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = LaunchEnvironment.childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return parse(String(decoding: data, as: UTF8.self))
    }

    /// `codex-cli 0.48.1` and `0.48.1` both become `v0.48.1`.
    package static func parse(_ output: String) -> String? {
        let token = output
            .split(whereSeparator: \.isWhitespace)
            .first { part in
                let candidate = part.hasPrefix("v") ? part.dropFirst() : part
                return candidate.contains(".") && candidate.allSatisfy {
                    $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter
                } && (candidate.first?.isNumber ?? false)
            }
        guard let token else { return nil }
        return token.hasPrefix("v") ? String(token) : "v\(token)"
    }
}
