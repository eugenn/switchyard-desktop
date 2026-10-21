import Foundation
import Testing
@testable import SwitchyardDesktopKit

/// Creates a directory containing an executable stub named `switchyard-server`.
private func makeBinDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let binary = directory.appendingPathComponent(SwitchyardBinaryLocator.binaryName)
    try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return directory
}

@Test func explicitPathWinsOverPath() throws {
    let explicitDirectory = try makeBinDirectory()
    let pathDirectory = try makeBinDirectory()
    defer {
        try? FileManager.default.removeItem(at: explicitDirectory)
        try? FileManager.default.removeItem(at: pathDirectory)
    }
    let explicit = explicitDirectory.appendingPathComponent(SwitchyardBinaryLocator.binaryName)

    let found = SwitchyardBinaryLocator.locate(
        explicitPath: explicit.path,
        searchPaths: [pathDirectory.path]
    )
    #expect(found == explicit)
}

@Test func pathLookupIsUsedWhenNoExplicitPathIsSet() throws {
    let pathDirectory = try makeBinDirectory()
    defer { try? FileManager.default.removeItem(at: pathDirectory) }

    let found = SwitchyardBinaryLocator.locate(searchPaths: [pathDirectory.path])
    #expect(found == pathDirectory.appendingPathComponent(SwitchyardBinaryLocator.binaryName))
}

@Test func anExplicitPathThatDoesNotExistFallsThroughToPath() throws {
    let pathDirectory = try makeBinDirectory()
    defer { try? FileManager.default.removeItem(at: pathDirectory) }

    let found = SwitchyardBinaryLocator.locate(
        explicitPath: "/nonexistent/switchyard-server",
        searchPaths: [pathDirectory.path]
    )
    #expect(found == pathDirectory.appendingPathComponent(SwitchyardBinaryLocator.binaryName))
}

@Test func nothingResolvesWhenNoCandidateIsExecutable() {
    let found = SwitchyardBinaryLocator.locate(
        explicitPath: "/nonexistent/a",
        searchPaths: ["/nonexistent/b"],
        fileManager: FileManager()
    )
    #expect(found == nil)
}

@Test func theDevelopmentFallbackRequiresAnExplicitDebugOptIn() {
    let candidates = SwitchyardBinaryLocator.candidates(
        explicitPath: "/explicit/switchyard-server",
        searchPaths: ["/bin", "/usr/bin"]
    )
    #expect(candidates.first?.path == "/explicit/switchyard-server")
    #expect(candidates.count == 3)

#if DEBUG
    let developmentCandidates = SwitchyardBinaryLocator.candidates(
        explicitPath: "/explicit/switchyard-server",
        searchPaths: ["/bin", "/usr/bin"],
        includeDevelopmentFallback: true
    )
    #expect(developmentCandidates.last == SwitchyardBinaryLocator.conventionalDevBuildPath)
    #expect(developmentCandidates.count == 4)
#endif
}

@Test func tildesInAnExplicitPathAreExpanded() {
    let candidates = SwitchyardBinaryLocator.candidates(
        explicitPath: "~/bin/switchyard-server",
        searchPaths: []
    )
    #expect(!candidates[0].path.contains("~"))
    #expect(candidates[0].path.hasSuffix("/bin/switchyard-server"))
}

@Test func bundledServerWinsOverUnrelatedPathInstallation() throws {
    let bundledDirectory = try makeBinDirectory()
    let pathDirectory = try makeBinDirectory()
    defer {
        try? FileManager.default.removeItem(at: bundledDirectory)
        try? FileManager.default.removeItem(at: pathDirectory)
    }
    let bundled = bundledDirectory.appendingPathComponent(SwitchyardBinaryLocator.binaryName)
    #expect(SwitchyardBinaryLocator.locate(searchPaths: [pathDirectory.path], bundledBinary: bundled) == bundled)
}

@Test func missingBundledServerDoesNotSilentlyLaunchExternalInstallation() throws {
    let pathDirectory = try makeBinDirectory()
    defer { try? FileManager.default.removeItem(at: pathDirectory) }
    #expect(SwitchyardBinaryLocator.locate(
        searchPaths: [pathDirectory.path],
        bundledBinary: URL(fileURLWithPath: "/missing/switchyard-desktop.app/Contents/Helpers/switchyard-server")
    ) == nil)
}

@Test func explicitDevelopmentOverrideWinsOverBundledServer() throws {
    let explicitDirectory = try makeBinDirectory()
    let bundledDirectory = try makeBinDirectory()
    defer {
        try? FileManager.default.removeItem(at: explicitDirectory)
        try? FileManager.default.removeItem(at: bundledDirectory)
    }
    let explicit = explicitDirectory.appendingPathComponent(SwitchyardBinaryLocator.binaryName)
    #expect(SwitchyardBinaryLocator.locate(
        explicitPath: explicit.path,
        searchPaths: [],
        bundledBinary: bundledDirectory.appendingPathComponent(SwitchyardBinaryLocator.binaryName)
    ) == explicit)
}
