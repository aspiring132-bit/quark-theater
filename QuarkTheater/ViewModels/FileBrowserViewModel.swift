import Combine
import Foundation
import os

@MainActor
final class FileBrowserViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "org.quarktheater.app", category: "FileBrowser")
    struct Folder: Equatable { let id: String; let name: String }
    @Published private(set) var folders: [Folder]
    @Published private(set) var files: [CloudFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasMore = false
    @Published private(set) var total: Int?
    @Published private(set) var searchQuery: String?
    private let client: QuarkClient
    private let diagnostics: Diagnostics
    private let accountID: String
    private var page = 0
    private let pageSize = 50

    var title: String { folders.last?.name ?? "我的网盘" }
    var canGoBack: Bool { folders.count > 1 }

    init(client: QuarkClient, diagnostics: Diagnostics, accountID: String = "") {
        self.client = client
        self.diagnostics = diagnostics
        self.accountID = accountID
        if !accountID.isEmpty, let active = BoundFolderStore.activeFolder(accountID: accountID) {
            self.folders = [Folder(id: active.id, name: active.name)]
        } else {
            self.folders = [Folder(id: "0", name: "我的网盘")]
        }
    }

    func reload() async {
        guard !isLoading else { return }
        await load(reset: true)
    }
    func search(_ query: String) async {
        guard !isLoading else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed.isEmpty ? nil : trimmed
        await load(reset: true)
    }
    func clearSearch() async {
        guard !isLoading else { return }
        searchQuery = nil
        await load(reset: true)
    }
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await load(reset: false)
    }

    func open(_ file: CloudFile) async {
        guard file.isDirectory, !isLoading else { return }
        folders.append(Folder(id: file.fileId, name: file.name))
        if !accountID.isEmpty {
            BoundFolderStore.setActiveFolder(id: file.fileId, name: file.name, accountID: accountID)
        }
        await load(reset: true)
    }

    func back() async {
        guard canGoBack, !isLoading else { return }
        folders.removeLast()
        if !accountID.isEmpty, let current = folders.last {
            BoundFolderStore.setActiveFolder(id: current.id, name: current.name, accountID: accountID)
        }
        await load(reset: true)
    }

    func switchToFolder(id: String, name: String) async {
        guard !isLoading else { return }
        folders = [Folder(id: id, name: name)]
        if !accountID.isEmpty {
            BoundFolderStore.setActiveFolder(id: id, name: name, accountID: accountID)
        }
        await load(reset: true)
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        if reset {
            page = 0
            files = []
            hasMore = false
            total = nil
        }
        defer { isLoading = false }
        let requestedPage = page + 1
        let currentFolder = folders.last ?? Folder(id: "0", name: "我的网盘")
        // Keep OSLog free of account-owned names and opaque folder identifiers.
        Self.logger.info("📂 FileBrowser: loading page \(requestedPage, privacy: .public)")
        do {
            let result: CloudFilePage
            if let searchQuery {
                result = try await client.searchFiles(query: searchQuery, page: requestedPage, pageSize: pageSize)
            } else {
                result = try await client.listFiles(parentID: currentFolder.id,
                    page: requestedPage, pageSize: pageSize)
            }
            try Task.checkCancellation()
            var knownIDs = Set(files.map(\.fileId))
            let unique = result.files.filter { knownIDs.insert($0.fileId).inserted }
            files.append(contentsOf: unique)
            page = requestedPage
            total = result.total
            hasMore = result.hasMore && !unique.isEmpty
            if result.hasMore && unique.isEmpty {
                errorMessage = "服务器重复返回同一页，已停止继续翻页；请刷新目录。"
            }
            Self.logger.info("✅ FileBrowser: 加载完成，获取到 \(result.files.count) 项文件 (新增 \(unique.count) 项, 总计 \(self.files.count) 项)")
            diagnostics.record("文件列表第 \(page) 页：收到 \(result.files.count) 条，新增 \(unique.count) 条")
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("❌ FileBrowser: load failed (error code \(Self.safeErrorCode(error), privacy: .public))")
            errorMessage = userFacingError(error)
            diagnostics.recordError(error, context: "文件列表")
        }
    }

    private static func safeErrorCode(_ error: Error) -> Int {
        if let quark = error as? QuarkError {
            switch quark {
            case .httpStatus(let code), .server(let code, _): return code
            case .credentialStorage(let code): return Int(code)
            default: return 0
            }
        }
        return (error as NSError).code
    }
}
