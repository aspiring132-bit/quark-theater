import Foundation

@MainActor
final class BoundFolderStore {
    private static let keyPrefix = "quark_bound_folders_"
    private static let namesKeyPrefix = "quark_bound_folder_names_"
    private static let activeFolderIdPrefix = "quark_active_folder_id_"
    private static let activeFolderNamePrefix = "quark_active_folder_name_"

    static func boundFolderIDs(accountID: String) -> Set<String> {
        let key = keyPrefix + accountID
        guard let array = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return Set(array)
    }

    static func boundFolderNames(accountID: String) -> [String: String] {
        let key = namesKeyPrefix + accountID
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    static func activeFolder(accountID: String) -> (id: String, name: String)? {
        let idKey = activeFolderIdPrefix + accountID
        let nameKey = activeFolderNamePrefix + accountID
        if let id = UserDefaults.standard.string(forKey: idKey),
           let name = UserDefaults.standard.string(forKey: nameKey),
           !id.isEmpty {
            return (id, name)
        }
        // Fallback to first bound folder if available
        let ids = UserDefaults.standard.stringArray(forKey: keyPrefix + accountID) ?? []
        let names = boundFolderNames(accountID: accountID)
        if let firstID = ids.first, let firstName = names[firstID] {
            return (firstID, firstName)
        }
        return nil
    }

    static func setActiveFolder(id: String, name: String, accountID: String) {
        guard !accountID.isEmpty else { return }
        let idKey = activeFolderIdPrefix + accountID
        let nameKey = activeFolderNamePrefix + accountID
        UserDefaults.standard.set(id, forKey: idKey)
        UserDefaults.standard.set(name, forKey: nameKey)
    }

    static func saveBoundFolders(folders: [(id: String, name: String)], accountID: String) {
        let idsKey = keyPrefix + accountID
        let namesKey = namesKeyPrefix + accountID
        let ids = folders.map(\.id)
        let dict = Dictionary(uniqueKeysWithValues: folders)
        UserDefaults.standard.set(ids, forKey: idsKey)
        UserDefaults.standard.set(dict, forKey: namesKey)

        if let first = folders.first {
            let current = activeFolder(accountID: accountID)
            if current == nil || !ids.contains(current?.id ?? "") {
                setActiveFolder(id: first.id, name: first.name, accountID: accountID)
            }
        } else {
            setActiveFolder(id: "0", name: "我的网盘", accountID: accountID)
        }
    }

    static func hasConfigured(accountID: String) -> Bool {
        let key = keyPrefix + accountID
        return UserDefaults.standard.object(forKey: key) != nil
    }

    static func clear(accountID: String) {
        let idsKey = keyPrefix + accountID
        let namesKey = namesKeyPrefix + accountID
        let idKey = activeFolderIdPrefix + accountID
        let nameKey = activeFolderNamePrefix + accountID
        UserDefaults.standard.removeObject(forKey: idsKey)
        UserDefaults.standard.removeObject(forKey: namesKey)
        UserDefaults.standard.removeObject(forKey: idKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }
}
