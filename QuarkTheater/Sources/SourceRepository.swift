import Foundation
import Combine

@MainActor
final class SourceRepository: ObservableObject {
    static let shared = SourceRepository()

    @Published private(set) var sources: [StorageSource] = []

    private let storageURL: URL
    private let credentialStore: SourceCredentialStore
    private var isLoaded = false

    init(storageURL: URL? = nil, credentialStore: SourceCredentialStore = .shared) {
        self.credentialStore = credentialStore
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("QuarkTheater", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("sources.json")
        }
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        loadSources()
    }

    func loadSources() {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                let decoded = try JSONDecoder().decode([StorageSource].self, from: data)
                self.sources = decoded
                return
            } catch {
                // If decoding fails, log and keep empty or migrate
            }
        }
        self.sources = []
    }

    func persistSources() throws {
        let data = try JSONEncoder().encode(sources)
        try data.write(to: storageURL, options: .atomic)
    }

    func allSources() -> [StorageSource] {
        loadIfNeeded()
        return sources
    }

    func source(id: String) -> StorageSource? {
        loadIfNeeded()
        return sources.first(where: { $0.id == id })
    }

    func saveSource(_ source: StorageSource) throws {
        loadIfNeeded()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        try persistSources()
    }

    /// Removes a storage source locally and purges its stored credentials.
    /// NON-DESTRUCTIVE: Strictly removes local configuration only. NEVER sends DELETE or MOVE to remote server.
    func removeSource(id: String) throws {
        loadIfNeeded()
        sources.removeAll(where: { $0.id == id })
        try persistSources()

        // Clean local Keychain credentials
        try credentialStore.deleteAllCredentials(for: id)

        // Clean bound folders locally
        BoundFolderStore.clear(accountID: id)
    }

    // MARK: - Legacy Quark Migration
    func migrateLegacyQuarkIfNeeded(account: Account?) {
        loadIfNeeded()
        guard sources.isEmpty, let account else { return }

        let bound = Array(BoundFolderStore.boundFolderIDs(accountID: account.accountId))
        let initialSource = StorageSource(
            id: account.accountId,
            type: .quark,
            displayName: "夸克网盘",
            accountHint: account.displayName,
            status: .connected,
            boundFolderIDs: bound,
            isEnabled: true
        )
        try? saveSource(initialSource)
    }

    // MARK: - Adapter Resolution
    private var customAdapters: [String: any StorageSourceAdapter] = [:]

    func registerCustomAdapter(_ adapter: any StorageSourceAdapter, for sourceID: String) {
        customAdapters[sourceID] = adapter
    }

    func adapter(for sourceID: String, client: QuarkClient? = nil) -> (any StorageSourceAdapter)? {
        if let custom = customAdapters[sourceID] {
            return custom
        }
        guard let source = source(id: sourceID) else {
            // Fallback for default client
            if let client {
                return QuarkSourceAdapter(sourceID: sourceID, client: client)
            }
            return nil
        }

        switch source.type {
        case .quark:
            if let client {
                return QuarkSourceAdapter(sourceID: sourceID, client: client)
            }
            return nil
        case .webdav:
            guard let endpointString = source.endpointURL, let url = URL(string: endpointString) else { return nil }
            return WebDAVSourceAdapter(sourceID: sourceID, endpointURL: url, username: source.username)
        case .smb:
            return SMBSourceAdapter(sourceID: sourceID, host: source.endpointURL ?? "", shareName: "")
        case .aliyun:
            return AliyunSourceAdapter(sourceID: sourceID)
        }
    }
}
