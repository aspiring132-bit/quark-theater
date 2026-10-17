import Combine
import Foundation
import os

@MainActor
final class SessionViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "org.quarktheater.app", category: "SessionViewModel")
    @Published private(set) var account: Account?
    @Published private(set) var challenge: QRLoginChallenge?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var isLoggingIn = false
    let isMock: Bool
    let diagnostics = Diagnostics()
    private(set) var client: QuarkClient?
    private var didRestore = false
    private var loginTask: Task<Void, Never>?
    private var loginGeneration = UUID()

    init() {
        isMock = ProcessInfo.processInfo.arguments.contains("--mock")
        do {
            if isMock { client = MockQuarkClient() } else { client = try LiveQuarkClient() }
        } catch {
            message = userFacingError(error)
            diagnostics.recordError(error, context: "初始化真实客户端")
        }
        diagnostics.record(isMock ? "显式 Mock 模式；未连接夸克" : "真实接口模式；等待账号验证")
    }

    func restore() async {
        guard !didRestore, let client else { return }
        didRestore = true
        isBusy = true
        defer { isBusy = false }
        do {
            Self.logger.info("🔄 SessionViewModel: 正在尝试恢复会话...")
            account = try await client.restoreSession()
            if let account {
                Self.logger.info("🎉 SessionViewModel: 会话恢复成功！账号: \(account.displayName, privacy: .public)")
                diagnostics.record("客户端已恢复保存的会话，并完成接口检查")
            } else {
                Self.logger.info("ℹ️ SessionViewModel: 未发现已保存的登录会话")
            }
        } catch {
            Self.logger.error("⚠️ SessionViewModel: 恢复会话遇到错误: \(error.localizedDescription, privacy: .public)")
            message = userFacingError(error)
            diagnostics.recordError(error, context: "会话恢复")
        }
    }

    func retryRestore() async {
        didRestore = false
        message = nil
        await restore()
    }

    func beginLogin() {
        guard !isBusy, let client else { return }
        cancelLogin()
        let generation = UUID()
        loginGeneration = generation
        isLoggingIn = true
        message = "正在获取二维码…"
        loginTask = Task {
            do {
                let challenge = try await client.beginQRCodeLogin()
                try Task.checkCancellation()
                guard generation == loginGeneration else { return }
                self.challenge = challenge
                message = isMock ? "这是 Mock 登录，不连接真实账号。" : "请用夸克手机 App 扫码，并在手机上确认。"
                // UI timeout only; do not claim this is the server token lifetime.
                let localDeadline = Date().addingTimeInterval(180)
                while !Task.isCancelled, Date() < localDeadline {
                    let result = try await client.pollQRCodeLogin(challenge)
                    try Task.checkCancellation()
                    guard generation == loginGeneration else { return }
                    switch result {
                    case .waiting:
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    case .expired:
                        self.challenge = nil
                        isLoggingIn = false
                        message = "二维码未能完成鉴权，请重新生成。"
                        return
                    case .authenticated(let account):
                        self.account = account
                        self.challenge = nil
                        isLoggingIn = false
                        message = nil
                        diagnostics.record(isMock ? "Mock 登录完成（模拟）" : "扫码鉴权完成，已建立本地账号分区")
                        return
                    }
                }
                guard generation == loginGeneration else { return }
                self.challenge = nil
                isLoggingIn = false
                message = "已达到本地 3 分钟等待上限，请重新生成二维码。"
            } catch {
                guard generation == loginGeneration, !Task.isCancelled else { return }
                self.challenge = nil
                isLoggingIn = false
                message = userFacingError(error)
                diagnostics.recordError(error, context: "二维码登录")
            }
        }
    }

    func enterMockDemo() {
        guard isMock, let mock = client as? MockQuarkClient else { return }
        cancelLogin()
        account = mock.enterDemo()
        message = nil
        diagnostics.record("Mock 演示模式已启用；示例目录和文件不来自夸克")
    }

    func cancelLogin() {
        guard isLoggingIn else { return }
        loginGeneration = UUID()
        loginTask?.cancel()
        loginTask = nil
        client?.cancelQRCodeLogin()
        challenge = nil
        isLoggingIn = false
    }

    func logout() async {
        guard !isBusy, let client else { return }
        cancelLogin()
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.logout()
            account = nil
            message = "已退出，安全凭据已清除。"
            diagnostics.record("退出登录完成")
        } catch {
            message = userFacingError(error)
            diagnostics.recordError(error, context: "退出登录")
        }
    }
}
