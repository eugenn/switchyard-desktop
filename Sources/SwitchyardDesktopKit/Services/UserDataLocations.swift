import Foundation

/// Every directory this app reads or writes outside its own bundle, in one
/// place — and the single point where a test process is redirected away from
/// them.
///
/// The files behind these paths are the user's: the Codex configuration their
/// editor depends on, the profile layer Start generates beside it, the record
/// that survives a crash, the log a real incident is read back from. A test that builds a
/// default-constructed object must not reach any of them. `DiagnosticLog`
/// already learned this the hard way and guarded its own file; the guard
/// belongs here instead, because every other default path had the same hole:
/// a `WizardModel()` with no injected stores would load the live session
/// record, delete the live Codex profile and overwrite the saved setup.
package enum UserDataLocations {
    /// True inside `swift test`, `xcodebuild test` and an Xcode test host.
    ///
    /// Neither the XCTest environment variable nor the XCTest class is present
    /// in a `swift test` run of a swift-testing suite, so the test bundle and
    /// SwiftPM's own helper are recognised as well. All three signals are kept:
    /// each covers a runner the others miss.
    package static var isUnderTest: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        return ProcessInfo.processInfo.arguments.contains {
            $0.contains(".xctest") || $0.hasSuffix("swiftpm-testing-helper") || $0.hasSuffix("/xctest")
        }
    }

    /// One directory per test process, so parallel runs cannot interleave.
    package static var testSandbox: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "SwitchyardDesktopTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }

    /// `~/Library/Application Support/switchyard-desktop`: routing config, saved setup,
    /// the active-route record, logs. Never inside the Switchyard checkout.
    package static var supportDirectory: URL {
        guard !isUnderTest else {
            return testSandbox.appendingPathComponent("switchyard-desktop", isDirectory: true)
        }
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("switchyard-desktop", isDirectory: true)
    }

    /// The home directory `$CODEX_HOME` defaults under, so a test never
    /// resolves the user's own `~/.codex/config.toml`.
    package static var home: URL {
        isUnderTest ? testSandbox : FileManager.default.homeDirectoryForCurrentUser
    }
}
