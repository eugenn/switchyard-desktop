import Foundation
import Security

@MainActor
package protocol JevAPIKeyStoring: AnyObject {
    func load() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

@MainActor
package final class InMemoryJevAPIKeyStore: JevAPIKeyStoring {
    private var key: String?

    package init(key: String? = nil) { self.key = key }
    package func load() throws -> String? { key }
    package func save(_ key: String) throws { self.key = key }
    package func delete() throws { key = nil }
}

@MainActor
package final class JevAPIKeyStore: JevAPIKeyStoring {
    package enum Failure: LocalizedError {
        case keychain(OSStatus)
        case unavailableInTests
        case invalidKey

        package var errorDescription: String? {
            switch self {
            case .keychain(let status): "Could not access the TypeSafe key in macOS Keychain (\(status))."
            case .unavailableInTests: "Tests must use an isolated TypeSafe key store."
            case .invalidKey: "Enter a nonempty TypeSafe API key without spaces or control characters."
            }
        }
    }

    package static func standard() -> any JevAPIKeyStoring {
        UserDataLocations.isUnderTest ? InMemoryJevAPIKeyStore() : JevAPIKeyStore()
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "switchyard-desktop.typesafe",
            kSecAttrAccount as String: "TYPESAFE_API_KEY",
        ]
    }

    package func load() throws -> String? {
        guard !UserDataLocations.isUnderTest else { throw Failure.unavailableInTests }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Failure.invalidKey
        }
        return key
    }

    package func save(_ key: String) throws {
        guard !UserDataLocations.isUnderTest else { throw Failure.unavailableInTests }
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw Failure.keychain(status)
        }
    }

    package func delete() throws {
        guard !UserDataLocations.isUnderTest else { throw Failure.unavailableInTests }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
