import Foundation
import Testing
@testable import SwitchyardDesktopKit

@Test func xcodeFindsThePreparedRuntimeInItsOwnCheckout() {
    let root = URL(fileURLWithPath: "/workspace/switchyard-desktop")
    let runtime = AppRuntimeLocator.liteLLMURL(
        bundleURL: URL(fileURLWithPath: "/DerivedData/Build/Products/Debug"), developmentRoot: root)
    #expect(runtime?.path == "/workspace/switchyard-desktop/build/litellm-runtime")
}

@Test func packagedAppsNeverUseTheDevelopmentRuntimeEvenIfTheirBundleIsIncomplete() {
    let app = URL(fileURLWithPath: "/Applications/switchyard-desktop.app")
    let runtime = AppRuntimeLocator.liteLLMURL(bundleURL: app, developmentRoot: URL(fileURLWithPath: "/workspace"))
    #expect(runtime == app.appendingPathComponent("Contents/Resources/LiteLLM"))
    #expect(AppRuntimeLocator.liteLLMURL(bundleURL: URL(fileURLWithPath: "/unbundled/release"), developmentRoot: nil) == nil)
}

@Test func runtimeReadinessRequiresTheLauncherAndLibrariesAsWellAsPython() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ["bin/python3.12", "launcher.py", "lib/python3.12/site-packages/litellm/__init__.py",
                 "lib/python3.12/site-packages/fastapi/__init__.py"]
    #expect(!AppRuntimeLocator.isLiteLLMAvailable(at: root))
    for (index, file) in files.enumerated() {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        if index == 0 { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        #expect(AppRuntimeLocator.isLiteLLMAvailable(at: root) == (index == files.count - 1))
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent(files[0]).path)
    #expect(!AppRuntimeLocator.isLiteLLMAvailable(at: root))
}

#if DEBUG
@Test func xcodePrefersTheCheckedInSnapshotsBuildBeforePathBinaries() throws {
    let candidates = SwitchyardBinaryLocator.candidates(bundledBinary: nil)
    #expect(candidates.first == AppRuntimeLocator.developmentServerURL)
    let packaged = URL(fileURLWithPath: "/Example.app/Contents/Helpers/switchyard-server")
    #expect(SwitchyardBinaryLocator.candidates(bundledBinary: packaged) == [packaged])
}

/// Opt-in: exercise exactly the Python path an unbundled Xcode run resolves,
/// without OAuth, network requests or user configuration writes.
@Test func preparedXcodeRuntimeImportsItsPinnedDependencies() throws {
    guard ProcessInfo.processInfo.environment["SWITCHYARD_DESKTOP_CHECK_XCODE_RUNTIME"] == "1" else { return }
    let runtime = try #require(AppRuntimeLocator.liteLLMURL())
    #expect(AppRuntimeLocator.isLiteLLMAvailable(at: runtime))
    let process = Process()
    process.executableURL = runtime.appendingPathComponent("bin/python3.12")
    process.arguments = ["-I", runtime.appendingPathComponent("launcher.py").path, "--check"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: data, as: UTF8.self).contains("LiteLLM 1.97.0 / FastAPI 0.136.3 OK"))
    let server = try #require(SwitchyardBinaryLocator.locate(bundledBinary: nil))
    #expect(server == AppRuntimeLocator.developmentServerURL)
}
#endif
