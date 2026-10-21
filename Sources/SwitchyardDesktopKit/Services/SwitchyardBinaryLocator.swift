import Foundation

/// Finds the `switchyard-server` executable this app launches.
///
/// App bundles use their own helper. An explicit override supports server development.
/// Unbundled debug builds prefer the server built from this checkout's snapshot.
/// Command-line builds can also discover a server on PATH; only debug builds may
/// explicitly opt into the NVIDIA checkout fallback.
package enum SwitchyardBinaryLocator {
    package static let binaryName = "switchyard-server"

    package static var bundledBinaryURL: URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(binaryName)")
    }

#if DEBUG
    /// Last-resort convenience default: a release build inside a local Switchyard checkout.
    package static var conventionalDevBuildPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/personal/NVIDIA/target/release/\(binaryName)")
    }
#endif

    /// - Parameters:
    ///   - explicitPath: a path the user set in the wizard's advanced field.
    ///   - searchPaths: directories to scan; defaults to the process `PATH`.
    ///   - fileManager: injectable for tests.
    package static func locate(
        explicitPath: String? = nil,
        searchPaths: [String]? = nil,
        fileManager: FileManager = .default,
        bundledBinary: URL? = bundledBinaryURL
    ) -> URL? {
        for candidate in candidates(
            explicitPath: explicitPath,
            searchPaths: searchPaths,
            fileManager: fileManager,
            bundledBinary: bundledBinary
        ) where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// The paths `locate` will try, in order. Exposed for tests and for error messages.
    package static func candidates(
        explicitPath: String? = nil,
        searchPaths: [String]? = nil,
        fileManager: FileManager = .default,
        includeDevelopmentFallback: Bool? = nil,
        bundledBinary: URL? = bundledBinaryURL
    ) -> [URL] {
        var result: [URL] = []

        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath))
        }

        if let bundledBinary {
            result.append(bundledBinary)
            return result
        }

        // A normal Xcode run uses the server built from this checkout's snapshot.
        // Explicit PATH injection stays deterministic for custom callers/tests.
        if searchPaths == nil, let server = AppRuntimeLocator.developmentServerURL {
            result.append(server)
        }

        // Defaults to the login shell's own PATH plus the conventional install
        // directories: a Finder or Xcode launch cannot see ~/.cargo/bin.
        let path = searchPaths ?? LaunchEnvironment.searchPaths
        result += path
            .filter { !$0.isEmpty }
            .map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                    .appendingPathComponent(binaryName)
            }

#if DEBUG
        let shouldIncludeDevelopmentFallback = includeDevelopmentFallback
            ?? (ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_ENABLE_DEV_BINARY_FALLBACK"] == "1")
        if shouldIncludeDevelopmentFallback {
            result.append(conventionalDevBuildPath)
        }
#endif
        return result
    }

    /// Shown when nothing resolves.
    package static var installInstructions: String {
        """
        switchyard-desktop could not find \(binaryName).

        Reinstall switchyard-desktop from its DMG to restore the bundled server.
        Developers can build it with scripts/build-switchyard.sh and set an
        explicit executable path in advanced settings.
        """
    }
}
