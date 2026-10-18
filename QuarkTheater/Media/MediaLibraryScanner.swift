import Foundation

struct ScannedMediaCandidate: Identifiable, Equatable {
    let file: CloudFile
    let parsedName: ParsedMediaName
    /// The immediate parent folder name (e.g. "S04", "大西洋帝国S01").
    let parentFolderName: String?
    /// The ancestor series folder name (e.g. "G 高堡奇人S01~S04", "【美剧】大西洋帝国.全5季.中英双字.1080P").
    let ancestorFolderName: String?
    var id: String { file.fileId }

    init(file: CloudFile, parsedName: ParsedMediaName, parentFolderName: String? = nil, ancestorFolderName: String? = nil) {
        self.file = file
        self.parsedName = parsedName
        self.parentFolderName = parentFolderName
        self.ancestorFolderName = ancestorFolderName
    }
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
        // Track: (id, depth, folderName, pathArray)
        // pathArray records all folder names from root down to this folder
        var pending: [(id: String, depth: Int, folderName: String?, path: [String])] = initialFolders.map {
            (id: $0, depth: 0, folderName: nil, path: [])
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
                            var childPath = folder.path
                            childPath.append(file.name)
                            pending.append((file.fileId, folder.depth + 1, file.name, childPath))
                        }
                    } else if file.isVideo {
                        // Extract show title and season from the entire folder hierarchy
                        let (detectedShow, detectedSeason) = FilenameParser.extractShowAndSeason(fromPath: folder.path)
                        
                        let immediateParent = folder.folderName
                        let ancestor = folder.path.count >= 2 ? folder.path[folder.path.count - 2] : nil
                        
                        let parsed = FilenameParser.parse(
                            file.name,
                            parentFolderName: immediateParent,
                            detectedShowTitle: detectedShow,
                            detectedSeasonNumber: detectedSeason
                        )
                        
                        candidates.append(ScannedMediaCandidate(
                            file: file,
                            parsedName: parsed,
                            parentFolderName: immediateParent,
                            ancestorFolderName: detectedShow ?? ancestor
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
