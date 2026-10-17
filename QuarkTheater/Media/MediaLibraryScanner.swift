import Foundation

struct ScannedMediaCandidate: Identifiable, Equatable {
    let file: CloudFile
    let parsedName: ParsedMediaName
    /// The immediate parent folder name (e.g. S01, S04).
    let parentFolderName: String?
    /// The ancestor show folder name (e.g. "G 高堡奇人S01~S04"), if parent is just a season.
    let ancestorFolderName: String?
    var id: String { file.fileId }
}

@MainActor
final class MediaLibraryScanner {
    private let pageSize = 100
    private let maximumFiles = 50_000

    func scan(
        client: QuarkClient,
        folderIDs: [String] = [],
        progress: @escaping (Int) -> Void = { _ in }
    ) async throws -> [ScannedMediaCandidate] {
        let initialFolders = folderIDs.isEmpty ? ["0"] : folderIDs
        // Track: (id, depth, parentFolderName, ancestorFolderName)
        var pending: [(id: String, depth: Int, parent: String?, ancestor: String?)] = initialFolders.map {
            (id: $0, depth: 0, parent: nil, ancestor: nil)
        }
        var visited = Set<String>(initialFolders)
        var candidates: [ScannedMediaCandidate] = []
        var seenFiles = Set<String>()
        var cursor = 0

        while cursor < pending.count {
            try Task.checkCancellation()
            let folder = pending[cursor]
            cursor += 1
            guard folder.depth <= 100 else {
                throw QuarkError.invalidResponse("目录深度超过扫描上限 100 层")
            }
            var page = 1
            while true {
                try Task.checkCancellation()
                let filesSeenBeforePage = seenFiles.count
                let result = try await client.listFiles(parentID: folder.id, page: page, pageSize: pageSize)
                for file in result.files where seenFiles.insert(file.fileId).inserted {
                    if file.isDirectory {
                        if visited.insert(file.fileId).inserted {
                            // If current folder has a valid show name (not S01/S02 and not system tags), pass it as ancestor
                            let currentIsSeason = file.name.range(of: #"^[Ss]\d+$"#, options: .regularExpression) != nil
                            let ancestorForChild = currentIsSeason ? (folder.ancestor ?? folder.parent) : file.name
                            pending.append((file.fileId, folder.depth + 1, file.name, ancestorForChild))
                        }
                    } else if file.isVideo {
                        // Effective show folder is ancestor if parent is just a season (e.g. S04)
                        let effectiveFolder = (folder.parent?.range(of: #"^[Ss]\d+$"#, options: .regularExpression) != nil)
                            ? (folder.ancestor ?? folder.parent)
                            : folder.parent
                        
                        let parsed = FilenameParser.parse(file.name, parentFolderName: effectiveFolder)
                        candidates.append(ScannedMediaCandidate(
                            file: file,
                            parsedName: parsed,
                            parentFolderName: folder.parent,
                            ancestorFolderName: folder.ancestor
                        ))
                    }
                    guard seenFiles.count <= maximumFiles else {
                        throw QuarkError.invalidResponse("扫描超过安全上限 50,000 个文件；请缩小范围")
                    }
                }
                progress(seenFiles.count)
                guard result.hasMore else { break }
                guard seenFiles.count > filesSeenBeforePage else {
                    throw QuarkError.invalidResponse("服务器重复返回扫描页；已停止，避免无限翻页")
                }
                page += 1
            }
        }
        return candidates
    }
}
