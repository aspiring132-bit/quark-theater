import Foundation

@MainActor
final class BoundFolderStore {
    private static let keyPrefix = "quark_bound_folders_"
    private static let namesKeyPrefix = "quark_bound_folder_names_"

    static func boundFolderIDs(accountID: String) -> Set<String> {
        let key = keyPrefix + accountID
        guard let array = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return Set(array)
    }

    static func boundFolderNames(accountID: String) -> [String: String] {
        let key = namesKeyPrefix + accountID
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    static func saveBoundFolders(folders: [(id: String, name: String)], accountID: String) {
        let idsKey = keyPrefix + accountID
        let namesKey = namesKeyPrefix + accountID
        let ids = folders.map(\.id)
        let dict = Dictionary(uniqueKeysWithValues: folders)
        UserDefaults.standard.set(ids, forKey: idsKey)
        UserDefaults.standard.set(dict, forKey: namesKey)
    }

    static func hasConfigured(accountID: String) -> Bool {
        let key = keyPrefix + accountID
        return UserDefaults.standard.object(forKey: key) != nil
    }

    static func clear(accountID: String) {
        let idsKey = keyPrefix + accountID
        let namesKey = namesKeyPrefix + accountID
        UserDefaults.standard.removeObject(forKey: idsKey)
        UserDefaults.standard.removeObject(forKey: namesKey)
    }
}
