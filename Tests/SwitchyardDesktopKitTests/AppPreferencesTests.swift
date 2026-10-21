import Foundation
import Testing
@testable import SwitchyardDesktopKit

private func temporaryURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("preferences.json")
}

@Test func preferencesDefaultToLongContextAllowed() {
    #expect(AppPreferences().allowsLongContext)
}

@Test func preferencesRoundTripThroughTheStore() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AppPreferencesStore(fileURL: url)

    #expect(try store.load() == nil)
    try store.save(AppPreferences(allowsLongContext: false))

    #expect(try store.load() == AppPreferences(allowsLongContext: false))
}

@Test func aPreferencesFileMissingAFieldKeepsItsDefault() throws {
    let empty = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))

    #expect(empty.allowsLongContext)
}

@Test func theDefaultPreferencesFileLivesInTheTestSandbox() {
    #expect(AppPreferencesStore.defaultURL.path.hasPrefix(UserDataLocations.testSandbox.path))
}
