import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func temporaryRegistryURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("managed-processes.json")
}

@MainActor
@Test func startedChildrenSurviveInTheRegistryUntilTheyAreForgotten() throws {
    let url = temporaryRegistryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let registry = ManagedProcessRegistry(fileURL: url)

    registry.record(
        ManagedProcessRecord(
            name: "switchyard-server", pid: 10, port: 4100,
            executablePath: "/opt/switchyard-server", startedAt: Date()
        )
    )
    registry.record(
        ManagedProcessRecord(
            name: "LiteLLM", pid: 11, port: 4101,
            executablePath: "/opt/python3.12", startedAt: Date()
        )
    )

    // A fresh instance reads what the crashed run wrote.
    let reread = ManagedProcessRegistry(fileURL: url)
    #expect(reread.records().map(\.pid).sorted() == [10, 11])

    reread.forget(pid: 10)
    #expect(ManagedProcessRegistry(fileURL: url).records().map(\.pid) == [11])
}

@Test @MainActor func aRestartedChildReplacesTheRecordForItsPID() {
    let url = temporaryRegistryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let registry = ManagedProcessRegistry(fileURL: url)

    registry.record(
        ManagedProcessRecord(
            name: "switchyard-server", pid: 10, port: 4100,
            executablePath: "/opt/old", startedAt: Date()
        )
    )
    registry.record(
        ManagedProcessRecord(
            name: "switchyard-server", pid: 10, port: 4200,
            executablePath: "/opt/new", startedAt: Date()
        )
    )

    #expect(registry.records().count == 1)
    #expect(registry.records().first?.executablePath == "/opt/new")
    #expect(registry.records().first?.port == 4200)
}

/// Bookkeeping must never be the reason routing cannot start.
@MainActor
@Test func anUnreadableRegistryReadsAsEmptyInsteadOfThrowing() throws {
    let url = temporaryRegistryURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try "not json".write(to: url, atomically: true, encoding: .utf8)

    let registry = ManagedProcessRegistry(fileURL: url)
    #expect(registry.records().isEmpty)

    registry.record(
        ManagedProcessRecord(
            name: "LiteLLM", pid: 3, port: 4101, executablePath: "/opt/py", startedAt: Date()
        )
    )
    #expect(registry.records().map(\.pid) == [3])
}
