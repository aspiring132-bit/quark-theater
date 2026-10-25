import Foundation

@MainActor
final class SMBSourceAdapter: StorageSourceAdapter {
    let sourceID: String
    let sourceType: StorageSourceType = .smb
    let host: String
    let shareName: String
    var isAvailable: Bool { false }

    static let blockerReason = "tvOS 缺少系统级 SMB 支持（需集成第三方 C 库 libsmb2）。当前版本缺少该编译依赖，推荐使用 WebDAV 挂载 NAS。"

    init(sourceID: String, host: String, shareName: String) {
        self.sourceID = sourceID
        self.host = host
        self.shareName = shareName
    }

    func testConnection() async throws -> SourceConnectionStatus {
        .blocked(reason: Self.blockerReason)
    }

    func listFiles(folderID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        throw QuarkError.invalidResponse(Self.blockerReason)
    }

    func playbackResource(fileID: String) async throws -> PlaybackResource {
        throw QuarkError.invalidResponse(Self.blockerReason)
    }
}
