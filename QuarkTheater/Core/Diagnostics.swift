import Foundation
import Combine

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

@MainActor
final class Diagnostics: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []

    /// Call only with application-owned messages. Never pass response bodies, URLs or credentials.
    func record(_ message: String) {
        entries.insert(DiagnosticEntry(message: message), at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
    }

    func recordError(_ error: Error, context: String) {
        if let error = error as? QuarkError {
            switch error {
            case .httpStatus(let status): record("\(context)：HTTP \(status)")
            case .server(let code, _): record("\(context)：业务错误 \(code)")
            case .forbidden: record("\(context)：403，停止自动重试")
            case .rateLimited: record("\(context)：429，停止自动重试")
            case .authenticationRequired: record("\(context)：需要重新登录")
            default: record("\(context)：接口/安全存储/播放条件未满足")
            }
        } else {
            let code = (error as NSError).code
            record("\(context)：系统错误码 \(code)")
        }
    }

    func clear() { entries.removeAll() }
}

func userFacingError(_ error: Error) -> String {
    if let error = error as? QuarkError { return error.errorDescription ?? "操作失败。" }
    if let error = error as? URLError {
        switch error.code {
        case .timedOut: return "网络请求超时，请检查网络后重试。"
        case .notConnectedToInternet: return "当前未连接互联网。"
        case .cancelled: return "操作已取消。"
        default: return "网络错误（\(error.code.rawValue)），请检查网络。"
        }
    }
    return "操作失败（错误码 \((error as NSError).code)）。请查看诊断记录。"
}
