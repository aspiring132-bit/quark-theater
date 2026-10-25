import Foundation
import Security

@MainActor
protocol KeychainInterface: AnyObject {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

@MainActor
final class DefaultKeychainInterface: KeychainInterface {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class SourceCredentialStore {
    static let shared = SourceCredentialStore()

    private let service = "QuarkTheater.SourceCredentials"
    private let keychain: KeychainInterface

    init(keychain: KeychainInterface = DefaultKeychainInterface()) {
        self.keychain = keychain
    }

    private func query(for sourceID: String, key: String = "secret") -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(sourceID):\(key)"
        ]
    }

    // MARK: - Secret / Password / Token
    func saveSecret(_ secret: String, for sourceID: String, key: String = "secret") throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteSecret(for: sourceID, key: key)
            return
        }
        let data = Data(trimmed.utf8)
        let q = query(for: sourceID, key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = keychain.update(q, attributes: attributes)
        if status == errSecItemNotFound {
            var item = q
            attributes.forEach { item[$0.key] = $0.value }
            status = keychain.add(item)
        }
        guard status == errSecSuccess else { throw QuarkError.credentialStorage(status) }
    }

    func loadSecret(for sourceID: String, key: String = "secret") throws -> String? {
        var q = query(for: sourceID, key: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(q, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw QuarkError.credentialStorage(status)
        }
        return value
    }

    func deleteSecret(for sourceID: String, key: String = "secret") throws {
        let q = query(for: sourceID, key: key)
        let status = keychain.delete(q)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QuarkError.credentialStorage(status)
        }
    }

    // MARK: - Cookies Storage
    func saveCookies(_ cookies: [HTTPCookie], for sourceID: String) throws {
        let stored = cookies.map { c in
            StoredCookie(name: c.name, value: c.value, domain: c.domain, path: c.path,
                         expires: c.expiresDate?.timeIntervalSince1970)
        }
        let data = try JSONEncoder().encode(stored)
        let q = query(for: sourceID, key: "cookies")
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var status = keychain.update(q, attributes: attributes)
        if status == errSecItemNotFound {
            var item = q
            attributes.forEach { item[$0.key] = $0.value }
            status = keychain.add(item)
        }
        guard status == errSecSuccess else { throw QuarkError.credentialStorage(status) }
    }

    func loadCookies(for sourceID: String) throws -> [HTTPCookie]? {
        var q = query(for: sourceID, key: "cookies")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(q, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw QuarkError.credentialStorage(status)
        }
        guard let data = result as? Data else { return nil }
        let stored = try JSONDecoder().decode([StoredCookie].self, from: data)
        return stored.compactMap { $0.toHTTPCookie() }
    }

    // MARK: - Full Source Clean
    func deleteAllCredentials(for sourceID: String) throws {
        try deleteSecret(for: sourceID, key: "secret")
        try deleteSecret(for: sourceID, key: "password")
        try deleteSecret(for: sourceID, key: "token")
        try deleteSecret(for: sourceID, key: "cookies")
    }
}
