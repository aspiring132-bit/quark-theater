import Foundation

@MainActor
final class QuarkSourceAdapter: StorageSourceAdapter {
    let sourceID: String
    let sourceType: StorageSourceType = .quark
    let client: QuarkClient
    var isAvailable: Bool { true }

    init(sourceID: String, client: QuarkClient) {
        self.sourceID = sourceID
        self.client = client
    }

    func testConnection() async throws -> SourceConnectionStatus {
        do {
            let account = try await client.restoreSession()
            if account != nil {
                return .connected
            } else {
                return .needsReauth
            }
        } catch QuarkError.authenticationRequired {
            return .needsReauth
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    func listFiles(folderID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        try await client.listFiles(parentID: folderID, page: page, pageSize: pageSize)
    }

    func playbackResource(fileID: String) async throws -> PlaybackResource {
        try await client.playbackResource(fileID: fileID)
    }
}
