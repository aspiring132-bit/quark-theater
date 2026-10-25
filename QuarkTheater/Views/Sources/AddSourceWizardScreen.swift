import SwiftUI

@MainActor
struct AddSourceWizardScreen: View {
    @ObservedObject var repository: SourceRepository = .shared
    let currentClient: QuarkClient?
    let currentAccount: Account?
    @Binding var isPresented: Bool
    var onSourceAdded: (StorageSource) -> Void = { _ in }

    @State private var selectedType: StorageSourceType = .webdav
    @State private var displayName: String = ""
    @State private var endpointURL: String = "https://"
    @State private var username: String = ""
    @State private var password: String = ""

    @State private var isTesting = false
    @State private var testResult: SourceConnectionStatus?
    @State private var testMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Top Header Action Bar
                HStack {
                    Button("取消") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("添加存储来源")
                        .font(.title2.bold())

                    Spacer()

                    if selectedType.isSupportedOnCurrentPlatform {
                        Button("保存并添加") {
                            saveSource()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BrandPalette.glassWhite)
                        .disabled(isTesting || !isFormValid)
                    }
                }

                // Step 1: Provider Selection
                VStack(alignment: .leading, spacing: 14) {
                    Text("1. 选择来源协议与提供商").font(.title3.bold())

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                        ForEach(StorageSourceType.allCases, id: \.self) { type in
                            let isSelected = (selectedType == type)
                            Button {
                                selectedType = type
                                testResult = nil
                                testMessage = nil
                                if displayName.isEmpty {
                                    displayName = type.displayName
                                }
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: type.iconName)
                                        .font(.title2)
                                        .foregroundStyle(type.isSupportedOnCurrentPlatform ? BrandPalette.iceBlue : .secondary)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(type.displayName)
                                                .font(.headline)
                                            if !type.isSupportedOnCurrentPlatform {
                                                Text("受阻/需凭据")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange.opacity(0.2), in: Capsule())
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        Text(type.platformSupportNote ?? "")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(BrandPalette.iceBlue)
                                    }
                                }
                                .padding(18)
                                .background(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(isSelected ? Color.white : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(24)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                .focusSection()

                // Step 2: Configuration Fields
                if selectedType == .webdav {
                    webdavConfigurationSection
                } else if selectedType == .quark {
                    quarkConfigurationSection
                } else if selectedType == .smb {
                    blockedProviderSection(
                        title: "SMB 局域网共享暂不可用",
                        icon: "server.rack",
                        reason: "Apple tvOS 运行环境缺少系统级 SMB 客户端接口，且当前工程未链接第三方 C 语言 SMB 库（如 libsmb2）。\n\n为了避免伪造网络请求造成播放失败，当前平台暂不开放直接挂载。推荐在群晖、威联通或极空间 NAS 上开启 WebDAV 服务，通过 WebDAV 挂载极速串流。"
                    )
                } else if selectedType == .aliyun {
                    blockedProviderSection(
                        title: "阿里云盘需要官方开发者凭据",
                        icon: "externaldrive.fill.badge.icloud",
                        reason: "依据官方开放平台（OpenAPI）规范，接入阿里云盘需要配置经过官方资质认证的 Client ID 与 Client Secret。\n\n当前尚未预置有效官方开发者凭据，为了严格遵守不伪造 live API 规范，该来源处于受阻等待配置状态。"
                    )
                }
            }
            .padding(60)
        }
        .onExitCommand {
            isPresented = false
        }
    }

    // MARK: - WebDAV Form
    private var webdavConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("2. WebDAV 服务器连接配置").font(.title3.bold())

            if WebDAVSourceAdapter.isPlaintextHTTP(url: endpointURL) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("当前使用明文 HTTP 协议。局域网内部可用，若经由公网串流建议改用 HTTPS 以保障凭据安全。")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                .padding(12)
                .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("服务器 WebDAV 地址 (URL)").font(.headline)
                TextField("https://nas.local:5005/dav", text: $endpointURL)
                    .frame(maxWidth: 900)
            }

            HStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("用户名").font(.headline)
                    TextField("admin", text: $username)
                        .frame(maxWidth: 420)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("密码或应用密码").font(.headline)
                    SecureField("••••••••", text: $password)
                        .frame(maxWidth: 420)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("自定义本地别名").font(.headline)
                TextField("如：家庭群晖 NAS", text: $displayName)
                    .frame(maxWidth: 900)
            }

            HStack(spacing: 20) {
                Button("测试连接") {
                    testWebDAVConnection()
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || endpointURL.isEmpty)

                if isTesting {
                    ProgressView()
                    Text("正在测试连接与验证权限…").font(.caption).foregroundStyle(.secondary)
                } else if let testResult {
                    HStack(spacing: 8) {
                        Image(systemName: testResult == .connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testResult == .connected ? .green : .orange)
                        Text(testResult.displayText)
                            .font(.callout.bold())
                            .foregroundStyle(testResult == .connected ? .green : .orange)
                    }
                }
            }
        }
        .padding(24)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .focusSection()
    }

    // MARK: - Quark Section
    private var quarkConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("2. 夸克网盘账号绑定").font(.title3.bold())

            if let account = currentAccount {
                VStack(alignment: .leading, spacing: 8) {
                    Text("检测到当前已登录夸克账号：\(account.displayName)")
                        .font(.headline)
                        .foregroundStyle(BrandPalette.glassWhite)
                    Text("添加后将该账号作为媒体来源纳入统一来源大厅。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义别名").font(.headline)
                    TextField("夸克主账号", text: $displayName)
                        .frame(maxWidth: 600)
                }
            } else {
                Text("当前未登录夸克网盘。请前往【影院】首页使用夸克手机 App 扫码登录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .focusSection()
    }

    // MARK: - Blocked Provider Explanation
    private func blockedProviderSection(title: String, icon: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.title3.bold())
            }

            Text(reason)
                .font(.callout)
                .foregroundStyle(BrandPalette.glassWhite.opacity(0.85))
                .lineSpacing(6)
        }
        .padding(24)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.2), lineWidth: 1))
        .focusSection()
    }

    private var isFormValid: Bool {
        switch selectedType {
        case .webdav:
            return !endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .quark:
            return currentAccount != nil
        case .smb, .aliyun:
            return false
        }
    }

    private func testWebDAVConnection() {
        guard let url = URL(string: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            testResult = .configError(reason: "URL 格式不合法")
            return
        }

        isTesting = true
        testResult = nil

        let tempID = "temp-webdav-\(UUID().uuidString)"
        if !password.isEmpty {
            try? SourceCredentialStore.shared.saveSecret(password, for: tempID, key: "password")
        }

        let adapter = WebDAVSourceAdapter(sourceID: tempID, endpointURL: url, username: username.isEmpty ? nil : username)
        Task {
            let status = (try? await adapter.testConnection()) ?? .unreachable(reason: "网络超时或拒绝连接")
            try? SourceCredentialStore.shared.deleteAllCredentials(for: tempID)
            testResult = status
            isTesting = false
        }
    }

    private func saveSource() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedType.displayName : displayName

        switch selectedType {
        case .webdav:
            let sourceID = "webdav_\(UUID().uuidString.prefix(8))"
            let source = StorageSource(
                id: sourceID,
                type: .webdav,
                displayName: name,
                accountHint: username.isEmpty ? nil : username,
                endpointURL: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.isEmpty ? nil : username,
                status: testResult ?? .connected,
                boundFolderIDs: ["/"],
                isEnabled: true
            )

            if !password.isEmpty {
                try? SourceCredentialStore.shared.saveSecret(password, for: sourceID, key: "password")
            }
            try? repository.saveSource(source)
            onSourceAdded(source)
            isPresented = false

        case .quark:
            guard let account = currentAccount else { return }
            let bound = Array(BoundFolderStore.boundFolderIDs(accountID: account.accountId))
            let source = StorageSource(
                id: account.accountId,
                type: .quark,
                displayName: name,
                accountHint: account.displayName,
                status: .connected,
                boundFolderIDs: bound,
                isEnabled: true
            )
            try? repository.saveSource(source)
            onSourceAdded(source)
            isPresented = false

        case .smb, .aliyun:
            break
        }
    }
}
