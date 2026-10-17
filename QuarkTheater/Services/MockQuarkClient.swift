import Foundation

/// Deterministic, in-memory demo only. This client never accesses Quark or credentials.
@MainActor
final class MockQuarkClient: QuarkClient {
    private let mockAccount = Account(
        accountId: "mock-account",
        displayName: "MOCK 演示账号（非真实夸克）",
        authenticationState: .authenticated
    )
    private var signedIn = false

    func restoreSession() async throws -> Account? { signedIn ? mockAccount : nil }
    func beginQRCodeLogin() async throws -> QRLoginChallenge { throw QuarkError.mockOnly }
    func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { throw QuarkError.mockOnly }
    func cancelQRCodeLogin() {}

    func enterDemo() -> Account {
        signedIn = true
        return mockAccount
    }

    func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        guard signedIn else { throw QuarkError.authenticationRequired }
        guard page > 0, (1...100).contains(pageSize), page <= Int.max / pageSize else {
            throw QuarkError.invalidResponse("Mock 分页参数无效")
        }
        let files: [CloudFile]
        if parentID == "0" {
            files = [
                CloudFile(fileId: "mock-folder", parentId: "0", name: "[MOCK] 示例目录",
                          size: 0, fileExtension: "", modifiedAt: nil, isDirectory: true),
                CloudFile(fileId: "mock-video", parentId: "0", name: "[MOCK] Example.2024.mp4",
                          size: 1_024_000, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
            ]
        } else if parentID == "mock-folder" {
            files = [
                CloudFile(fileId: "mock-episode", parentId: parentID, name: "[MOCK] Series.S01E02.mkv",
                          size: 2_048_000, fileExtension: "mkv", modifiedAt: nil, isDirectory: false)
            ]
        } else {
            throw QuarkError.invalidResponse("Mock 目录不存在")
        }
        let start = min((page - 1) * pageSize, files.count)
        let end = min(start + pageSize, files.count)
        return CloudFilePage(files: Array(files[start..<end]), page: page, pageSize: pageSize, total: files.count)
    }

    func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty, page > 0, (1...100).contains(pageSize) else { throw QuarkError.invalidSearchQuery }
        let pageResult = try await listFiles(parentID: "0", page: 1, pageSize: 100)
        let root = pageResult.files
        let matches = root.filter { $0.name.lowercased().contains(term) }
        let start = min((page - 1) * pageSize, matches.count)
        let end = min(start + pageSize, matches.count)
        return CloudFilePage(files: Array(matches[start..<end]), page: page, pageSize: pageSize, total: matches.count)
    }

    func playbackResource(fileID: String) async throws -> PlaybackResource { throw QuarkError.mockOnly }
    func logout() async throws { signedIn = false }
}
