import Combine
import Foundation
import os

@MainActor
final class FileBrowserViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "org.quarktheater.app", category: "FileBrowser")
    struct Folder { let id: String; let name: String }
    @Published private(set) var folders = [Folder(id: "0", name: "我的网盘")]
    @Published private(set) var files: [CloudFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasMore = false
    @Published private(set) var total: Int?
    @Published private(set) var searchQuery: String?
    private let client: QuarkClient
    private let diagnostics: Diagnostics
    private var page = 0
    private let pageSize = 50

    var title: String { folders.last?.name ?? "我的网盘" }
    var canGoBack: Bool { folders.count > 1 }

    init(client: QuarkClient, diagnostics: Diagnostics) {
        self.client = client
        self.diagnostics = diagnostics
    }

    func reload() async { await load(reset: true) }
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed.isEmpty ? nil : trimmed
        await load(reset: true)
    }
    func clearSearch() async { searchQuery = nil; await load(reset: true) }
    func loadMore() async {
        guard hasMore else { return }
        await load(reset: false)
    }

    func open(_ file: CloudFile) async {
        guard file.isDirectory, !isLoading else { return }
        folders.append(Folder(id: file.fileId, name: file.name))
        await load(reset: true)
    }

    func back() async {
        guard canGoBack, !isLoading else { return }
        folders.removeLast()
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
        Self.logger.info("📂 FileBrowser: 正在加载目录 [\(self.folders.last?.name ?? "我的网盘", privacy: .public)] (ID: \(self.folders.last?.id ?? "0", privacy: .public)), 第 \(requestedPage) 页...")
        do {
            let result: CloudFilePage
            if let searchQuery {
                result = try await client.searchFiles(query: searchQuery, page: requestedPage, pageSize: pageSize)
            } else {
                result = try await client.listFiles(parentID: folders.last?.id ?? "0",
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
            Self.logger.error("❌ FileBrowser: 加载目录失败: \(error.localizedDescription, privacy: .public)")
            errorMessage = userFacingError(error)
            diagnostics.recordError(error, context: "文件列表")
        }
    }
}
