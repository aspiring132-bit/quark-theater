import Foundation
import Security

@MainActor
final class TMDBCredentialStore {
    private let service = "QuarkTheater.TMDB"
    private let account = "tmdb-v4-read-token"
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

    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == -34018 /* errSecMissingEntitlement, common in Simulator */ {
            guard let url = fallbackFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw QuarkError.credentialStorage(status) }
        return value
    }

    func effectiveToken() -> String {
        if let custom = try? load(), !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TMDBService.builtInAPIKey
    }

    func save(_ token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TMDBError.missingAPIKey }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
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
        guard status == errSecSuccess || status == errSecItemNotFound || status == -34018 else { throw QuarkError.credentialStorage(status) }
    }
}
