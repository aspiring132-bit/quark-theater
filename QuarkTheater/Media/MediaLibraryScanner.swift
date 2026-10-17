import Foundation

struct ScannedMediaCandidate: Identifiable, Equatable {
    let file: CloudFile
    let parsedName: ParsedMediaName
    /// The immediate parent folder name (used for scraping context).
    let parentFolderName: String?
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
        // Track (folderID, depth, parentFolderName)
        var pending: [(id: String, depth: Int, folderName: String?)] = initialFolders.map { (id: $0, depth: 0, folderName: nil) }
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
                            // Pass this folder's own name as the parent context for its children
                            pending.append((file.fileId, folder.depth + 1, file.name))
                        }
                    } else if file.isVideo {
                        // Parse filename with parent folder context
                        let parsed = FilenameParser.parse(file.name, parentFolderName: folder.folderName)
                        candidates.append(ScannedMediaCandidate(
                            file: file,
                            parsedName: parsed,
                            parentFolderName: folder.folderName
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
