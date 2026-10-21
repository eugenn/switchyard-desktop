import Foundation

/// Packaged apps are self-contained. Xcode/SwiftPM debug executables reuse only
/// this checkout's prepared runtime; nothing is installed when the app starts.
package enum AppRuntimeLocator {
    package static var developmentRoot: URL? {
        #if DEBUG
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #else
        nil
        #endif
    }

    package static func liteLLMURL(
        bundleURL: URL = Bundle.main.bundleURL,
        developmentRoot: URL? = developmentRoot
    ) -> URL? {
        if bundleURL.pathExtension == "app" {
            return bundleURL.appendingPathComponent("Contents/Resources/LiteLLM")
        }
        return developmentRoot?.appendingPathComponent("build/litellm-runtime")
    }

    package static func isLiteLLMAvailable(at runtime: URL?, fileManager: FileManager = .default) -> Bool {
        guard let runtime else { return false }
        return fileManager.isExecutableFile(atPath: runtime.appendingPathComponent("bin/python3.12").path)
            && ["launcher.py", "lib/python3.12/site-packages/litellm/__init__.py",
                "lib/python3.12/site-packages/fastapi/__init__.py"].allSatisfy {
                fileManager.isReadableFile(atPath: runtime.appendingPathComponent($0).path)
            }
    }

    package static var developmentServerURL: URL? {
        developmentRoot?.appendingPathComponent("build/switchyard-target/release/switchyard-server")
    }

    package static var missingLiteLLMMessage: String {
        if Bundle.main.bundleURL.pathExtension != "app", developmentRoot != nil {
            return "The local LiteLLM runtime is not ready. Run scripts/prepare-xcode.sh once, then run again in Xcode."
        }
        return "The bundled LiteLLM runtime is incomplete. Rebuild or reinstall the complete switchyard-desktop app."
    }
}
