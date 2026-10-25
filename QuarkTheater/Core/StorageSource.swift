import Foundation
import SwiftUI

extension StorageSourceType {
    var isSupportedOnCurrentPlatform: Bool {
        switch self {
        case .quark, .webdav:
            return true
        case .smb, .aliyun:
            return false
        }
    }

    var platformSupportNote: String? {
        switch self {
        case .quark:
            return "支持夸克网盘扫码授权与 4K 高速专线串流。"
        case .webdav:
            return "标准 RFC 4918 协议，支持群晖、威联通、极空间 NAS 及 Alist 挂载。"
        case .smb:
            return "tvOS 平台缺少系统级用户态 SMB 支持（需集成第三方 C 库 libsmb2）。当前版本编译目标缺少该依赖，推荐开启 NAS 的 WebDAV 服务连接。"
        case .aliyun:
            return "需要配置官方开放平台 OpenAPI 开发者凭据（Client ID 与 Secret），当前尚未配置。"
        }
    }
}

enum SourceConnectionStatus: Codable, Equatable {
    case connected
    case scanning
    case needsReauth
    case unreachable(reason: String)
    case configError(reason: String)
    case rateLimited(retryAfter: TimeInterval?)
    case blocked(reason: String)

    var displayText: String {
        switch self {
        case .connected: return "已连接"
        case .scanning: return "正在扫描…"
        case .needsReauth: return "需要重新授权"
        case .unreachable(let reason): return "网络不可达：\(reason)"
        case .configError(let reason): return "配置错误：\(reason)"
        case .rateLimited: return "请求受限，请稍后重试"
        case .blocked(let reason): return "暂不可用：\(reason)"
        }
    }

    var isOperational: Bool {
        switch self {
        case .connected, .scanning: return true
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, reason, retryAfter
    }

    private enum StatusType: String, Codable {
        case connected, scanning, needsReauth, unreachable, configError, rateLimited, blocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StatusType.self, forKey: .type)
        switch type {
        case .connected:
            self = .connected
        case .scanning:
            self = .scanning
        case .needsReauth:
            self = .needsReauth
        case .unreachable:
            let reason = try container.decode(String.self, forKey: .reason)
            self = .unreachable(reason: reason)
        case .configError:
            let reason = try container.decode(String.self, forKey: .reason)
            self = .configError(reason: reason)
        case .rateLimited:
            let retryAfter = try container.decodeIfPresent(TimeInterval.self, forKey: .retryAfter)
            self = .rateLimited(retryAfter: retryAfter)
        case .blocked:
            let reason = try container.decode(String.self, forKey: .reason)
            self = .blocked(reason: reason)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connected:
            try container.encode(StatusType.connected, forKey: .type)
        case .scanning:
            try container.encode(StatusType.scanning, forKey: .type)
        case .needsReauth:
            try container.encode(StatusType.needsReauth, forKey: .type)
        case .unreachable(let reason):
            try container.encode(StatusType.unreachable, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .configError(let reason):
            try container.encode(StatusType.configError, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .rateLimited(let retryAfter):
            try container.encode(StatusType.rateLimited, forKey: .type)
            try container.encodeIfPresent(retryAfter, forKey: .retryAfter)
        case .blocked(let reason):
            try container.encode(StatusType.blocked, forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

struct StorageSource: Codable, Identifiable, Equatable {
    let id: String
    var type: StorageSourceType
    var displayName: String
    var accountHint: String?
    var endpointURL: String?
    var username: String?
    var status: SourceConnectionStatus
    var boundFolderIDs: [String]
    var lastScanAt: Date?
    var lastErrorSummary: String?
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: String,
        type: StorageSourceType,
        displayName: String,
        accountHint: String? = nil,
        endpointURL: String? = nil,
        username: String? = nil,
        status: SourceConnectionStatus = .connected,
        boundFolderIDs: [String] = [],
        lastScanAt: Date? = nil,
        lastErrorSummary: String? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.accountHint = accountHint
        self.endpointURL = endpointURL
        self.username = username
        self.status = status
        self.boundFolderIDs = boundFolderIDs
        self.lastScanAt = lastScanAt
        self.lastErrorSummary = lastErrorSummary
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

@MainActor
protocol StorageSourceAdapter: AnyObject {
    var sourceID: String { get }
    var sourceType: StorageSourceType { get }
    var isAvailable: Bool { get }
    func testConnection() async throws -> SourceConnectionStatus
    func listFiles(folderID: String, page: Int, pageSize: Int) async throws -> CloudFilePage
    func playbackResource(fileID: String) async throws -> PlaybackResource
}
