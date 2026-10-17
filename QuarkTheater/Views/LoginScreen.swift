import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

@MainActor
struct LoginScreen: View {
    @ObservedObject var model: SessionViewModel
    var body: some View {
        HStack(alignment: .center, spacing: 70) {
            if let challenge = model.challenge, !model.isMock {
                QRCodeView(value: challenge.qrURL.absoluteString)
            } else {
                Image(systemName: model.isMock ? "testtube.2" : "qrcode")
                    .font(.system(size: 140)).frame(width: 360, height: 360)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
            }
            VStack(alignment: .leading, spacing: 24) {
                Text(model.isMock ? "Mock 登录验证" : "连接夸克网盘").font(.title.bold())
                Text(model.message ?? "在电视生成二维码后，用夸克手机 App 扫码。凭据只保存在本机 Keychain。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.isBusy { ProgressView("正在恢复会话") }
                if model.isLoggingIn {
                    ProgressView("等待手机确认")
                    Button("取消登录") { model.cancelLogin() }
                } else {
                    HStack(spacing: 20) {
                        Button(model.isMock ? "进入 Mock 演示" : "生成登录二维码") {
                            if model.isMock { model.enterMockDemo() } else { model.beginLogin() }
                        }
                        .disabled(model.isBusy || model.client == nil)

                        Button("恢复已保存会话") {
                            Task { await model.retryRestore() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy || model.client == nil)
                    }
                }
                Text("不会要求你在源码中填写个人 Cookie。").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.onDisappear { model.cancelLogin() }
    }
}

private struct QRCodeView: View {
    let value: String
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                Text("二维码生成失败，请重新获取。").foregroundStyle(.black)
            }
        }
        .frame(width: 320, height: 320).padding(24)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("使用夸克手机 App 扫描此二维码")
    }
}
