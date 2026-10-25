import Foundation

@MainActor
final class AliyunSourceAdapter: StorageSourceAdapter {
    let sourceID: String
    let sourceType: StorageSourceType = .aliyun
    var isAvailable: Bool { false }

    static let blockerReason = "需要配置官方阿里云盘 OpenAPI Client ID 与 Client Secret，当前未配置。"

    init(sourceID: String) {
        self.sourceID = sourceID
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
