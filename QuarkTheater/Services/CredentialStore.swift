import Foundation
import Security

@MainActor
protocol CredentialStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

/// Stores the account namespace and full cookie attributes together, never in preferences.
@MainActor
final class KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account = "quark-session-v1"

    init(service: String = "QuarkTheater.QuarkCredentials") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw QuarkError.credentialStorage(status) }
        guard let data = result as? Data else { throw QuarkError.credentialStorage(errSecDecode) }
        return data
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw QuarkError.credentialStorage(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QuarkError.credentialStorage(status)
        }
    }
}

struct StoredQuarkSession: Codable {
    let account: Account
    let cookiePropertyLists: [Data]

    init(account: Account, cookies: [HTTPCookie]) throws {
        self.account = account
        cookiePropertyLists = try cookies.map { cookie in
            guard let properties = cookie.properties else {
                throw QuarkError.invalidResponse("Cookie 缺少属性")
            }
            let values = Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) })
            return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        }
    }

    func cookies() throws -> [HTTPCookie] {
        try cookiePropertyLists.map { data in
            guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let cookie = HTTPCookie(properties: Dictionary(uniqueKeysWithValues: values.map { (HTTPCookiePropertyKey($0.key), $0.value) })) else {
                throw QuarkError.invalidResponse("已保存 Cookie 无法还原")
            }
            return cookie
        }
    }
}
