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

    private var fallbackFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("QuarkTheater", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials_\(service).dat")
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == -34018 /* errSecMissingEntitlement, common in Simulator */ {
            guard let url = fallbackFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? Data(contentsOf: url)
        }
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
        if status == -34018 /* errSecMissingEntitlement */ {
            if let url = fallbackFileURL {
                try data.write(to: url, options: .atomic)
                return
            }
        }
        guard status == errSecSuccess else { throw QuarkError.credentialStorage(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if let url = fallbackFileURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        guard status == errSecSuccess || status == errSecItemNotFound || status == -34018 else {
            throw QuarkError.credentialStorage(status)
        }
    }
}

struct StoredCookie: Codable {
    let name: String
    let value: String
    var domain: String?
    var path: String?
    var expires: Double?

    func toHTTPCookie() -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain ?? ".quark.cn",
            .path: path ?? "/"
        ]
        if let expires, expires > 0 {
            props[.expires] = Date(timeIntervalSince1970: expires)
        }
        return HTTPCookie(properties: props)
    }
}

struct StoredQuarkSession: Codable {
    let account: Account
    var cookiesList: [StoredCookie] = []
    var cookiePropertyLists: [Data]? = nil

    init(account: Account, cookies: [HTTPCookie]) {
        self.account = account
        self.cookiesList = cookies.map { c in
            StoredCookie(name: c.name, value: c.value, domain: c.domain, path: c.path,
                         expires: c.expiresDate?.timeIntervalSince1970)
        }
        self.cookiePropertyLists = nil
    }

    func cookies() throws -> [HTTPCookie] {
        if !cookiesList.isEmpty {
            return cookiesList.compactMap { $0.toHTTPCookie() }
        }
        if let cookiePropertyLists {
            return try cookiePropertyLists.map { data in
                guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let cookie = HTTPCookie(properties: Dictionary(uniqueKeysWithValues: values.map { (HTTPCookiePropertyKey($0.key), $0.value) })) else {
                    throw QuarkError.invalidResponse("已保存 Cookie 无法还原")
                }
                return cookie
            }
        }
        return []
    }
}
