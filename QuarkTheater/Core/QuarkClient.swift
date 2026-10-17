import Foundation

@MainActor
protocol QuarkClient: AnyObject {
    func restoreSession() async throws -> Account?
    func beginQRCodeLogin() async throws -> QRLoginChallenge
    func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState
    func cancelQRCodeLogin()
    func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage
    func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage
    func playbackResource(fileID: String) async throws -> PlaybackResource
    func logout() async throws
}

enum QuarkError: Error, LocalizedError, Equatable {
    case authenticationRequired
    case qrExpired
    case forbidden
    case rateLimited
    case httpStatus(Int)
    case server(code: Int, message: String)
    case invalidResponse(String)
    case unsupportedPlayback(String)
    case credentialStorage(Int32)
    case mockOnly
    case invalidSearchQuery

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "登录状态无效或已过期，请重新扫码登录。"
        case .qrExpired: return "二维码已失效，请重新生成。"
        case .forbidden: return "服务器拒绝访问（403）。请检查账号权限、会员限制或风控状态；自动重试已停止。"
        case .rateLimited: return "请求过于频繁（429），请稍后手动重试。"
        case .httpStatus(let code): return "服务器返回 HTTP \(code)。"
        case .server(let code, _): return "夸克接口返回业务错误 \(code)。请在官方客户端检查账号状态。"
        case .invalidResponse(let reason): return "接口响应不符合已核实格式：\(reason)"
        case .unsupportedPlayback(let reason): return "当前直连播放受限：\(reason)"
        case .credentialStorage(let status): return "安全凭据存储失败（Keychain \(status)）。"
        case .mockOnly: return "当前是 Mock 模式，不连接真实夸克账号，也不代表接口已打通。"
        case .invalidSearchQuery: return "搜索词不能为空，且每页数量必须在 1 到 100 之间。"
        }
    }
}
