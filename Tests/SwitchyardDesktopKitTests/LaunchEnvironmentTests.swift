import Foundation
import Testing
@testable import SwitchyardDesktopKit

@Test func mergedPathsPreferTheProcessThenTheLoginShellThenConventions() {
    let merged = LaunchEnvironment.mergedSearchPaths(
        processPath: "/usr/bin:/bin",
        loginShellPath: "/opt/tool/bin:/usr/bin",
        conventional: ["/usr/local/bin", "/opt/tool/bin"]
    )

    #expect(merged == ["/usr/bin", "/bin", "/opt/tool/bin", "/usr/local/bin"])
}

@Test func mergedPathsSurviveAMinimalFinderLaunch() {
    // What a Finder or Xcode launch actually hands the app.
    let merged = LaunchEnvironment.mergedSearchPaths(
        processPath: "/usr/bin:/bin:/usr/sbin:/sbin",
        loginShellPath: nil,
        conventional: ["/usr/local/bin", "~/.local/bin"]
    )

    #expect(merged.contains("/usr/local/bin"))
    #expect(merged.contains("~/.local/bin"))
}

@Test func mergedPathsIgnoreEmptySegmentsAndDeduplicateTildes() {
    let home = UserDataLocations.home.path
    let merged = LaunchEnvironment.mergedSearchPaths(
        processPath: "::\(home)/.local/bin:",
        loginShellPath: "~/.local/bin",
        conventional: ["~/.local/bin"]
    )

    #expect(merged == ["\(home)/.local/bin"])
}

@Test func mergedPathsFallBackToConventionsWithoutAnyEnvironment() {
    let merged = LaunchEnvironment.mergedSearchPaths(
        processPath: nil,
        loginShellPath: nil,
        conventional: ["/usr/bin", "/bin"]
    )

    #expect(merged == ["/usr/bin", "/bin"])
}

@Test func locateFindsAnExecutableAndSkipsNonExecutableMatches() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let empty = root.appendingPathComponent("empty", isDirectory: true)
    let plain = root.appendingPathComponent("plain", isDirectory: true)
    let real = root.appendingPathComponent("real", isDirectory: true)
    for directory in [empty, plain, real] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    // Same name, but not executable: it must not win over the real one.
    try "".write(to: plain.appendingPathComponent("codex"), atomically: true, encoding: .utf8)
    let executable = real.appendingPathComponent("codex")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path
    )

    let found = LaunchEnvironment.locate(
        "codex",
        searchPaths: [empty.path, plain.path, real.path, "/no/such/directory"]
    )

    #expect(found?.path == executable.path)
    #expect(LaunchEnvironment.locate("codex", searchPaths: [empty.path]) == nil)
}

@Test func childEnvironmentKeepsItsBaseAndReplacesOnlyPath() {
    let environment = LaunchEnvironment.childEnvironment(["CODEX_HOME": "/tmp/codex", "PATH": "/bin"])

    #expect(environment["CODEX_HOME"] == "/tmp/codex")
    #expect(environment["PATH"] != "/bin")
    #expect(environment["PATH"]?.contains("/usr/bin") == true)
    // Tildes are expanded, or the child process cannot use the entry.
    #expect(environment["PATH"]?.contains("~") == false)
    #expect(environment["PATH"]?.contains(UserDataLocations.testSandbox.path) == true)
}

@Test func testsNeverLaunchTheUsersLoginShell() {
    #expect(LaunchEnvironment.loginShellPath() == nil)
}
