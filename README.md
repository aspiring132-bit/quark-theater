# Quark Theater

原生 Swift / SwiftUI tvOS 客户端，直接访问夸克服务。当前是可交给 Mac 做 Xcode 编译和设备验证的开发版本；真实账号及 AVPlayer 兼容性仍未验证。

## 开发进度

[完整开发清单：64 项](DEVELOPMENT-CHECKLIST.md)。每项分别标记交付状态与验证证据，不将 Mock、静态检查或源码阅读等同于真实 API / 真机验证。

## 本轮交付

- 实际 [Xcode 工程](QuarkTheater.xcodeproj)，tvOS App + XCTest target + shared scheme。
- SwiftUI 中文首页、二维码登录、目录导航、分页、账号设置、脱敏诊断。
- `QuarkClient` 协议、真实 URLSession 适配、Keychain 会话凭据、显式 Mock。
- 账号、云文件、媒体、剧集、历史、临时播放会话模型。
- SQLite 观看历史、最近/已完成历史页和账号隔离。
- 按需取地址、AVPlayer 播放视图、进度保存、续播与有限错误恢复代码。**未在 Apple SDK、真实链接或设备上验证；夸克要求的 Referer/Origin 不能通过 AVURLAsset 的公开通用选项设置。**
- 网盘搜索、递归媒体扫描与增量差异、文件名解析、TMDB 查询/保守匹配评分和手动确认、收藏、Keychain Token 设置。
- 适配器测试、模型/分页/重试/Cookie/SQLite 测试和结构检查。

## 验证状态

| 项目 | 当前证据 |
|---|---|
| 两个 GitHub 仓库、许可证、协议源码 | 已在线核实，并固定到提交 |
| 工程文件和源码静态检查 | 见 [本轮验证报告](docs/VALIDATION.md) |
| Swift 类型检查 / Xcode 编译 | 未执行：当前 Windows 没有 Swift、Xcode 或 Apple SDK |
| XCTest | 已编写，未在 Apple 环境执行 |
| 真实二维码、Cookie、文件列表 | 代码按已核实源码实现；未用用户账号联调 |
| 真实播放地址及 AVPlayer | 播放链路已实现；真实地址、HTTP 鉴权头和设备播放未验证 |
| Apple TV 签名安装 / Siri Remote / 电视显示效果 | 未验证 |

## 在 Mac 打开

1. 将整个 `quark-theater` 文件夹复制到 Mac，保留所有子目录。
2. 用 Xcode 打开 `QuarkTheater.xcodeproj`；工程已生成，无需 XcodeGen 或第三方 Swift 包。
3. 选择 `QuarkTheater` scheme 和可用的 tvOS Simulator。先使用模拟器检查编译与界面，再做真机登录/播放验收。
4. 真机安装须配置自己的 Development Team 和唯一 Bundle Identifier，详见 [Apple TV 安装说明](docs/APPLE-TV-INSTALL.md)。

最低版本暂设 **tvOS 16.0**，依据 `NavigationStack` 等所选 API；不是对你的设备型号或系统版本的判断。确认 Apple TV 型号与 tvOS、Mac/Xcode 后再冻结兼容矩阵。若安装的 Xcode 已不支持该部署目标，须明确调整并重新验证。

## 如何使用

### 首次启动与夸克登录

1. 在 Mac 用 Xcode 打开 `QuarkTheater.xcodeproj`，选择 `QuarkTheater` scheme 和 tvOS Simulator，或按 [Apple TV 安装说明](docs/APPLE-TV-INSTALL.md) 配对真机并设置自己的签名。
2. 第一次启动会进入登录页。选择“生成登录二维码”，用手机夸克 App 扫码并在手机上确认。登录凭据保存在设备 Keychain 中；项目不会在源码里保存个人 Cookie。
3. 想离线查看界面时，在 Xcode 的 Scheme Run Arguments 中加入 `--mock`。页面会标明 Mock；它只用于演示界面，不代表夸克登录成功。删掉参数并重启即可恢复真实模式。

### 浏览和播放

登录后可从首页进入网盘文件，打开目录、翻页或搜索文件。选择视频后，App 会按需获取短期下载地址并交给 AVPlayer；观看进度保存在本机 SQLite，可从历史/继续观看入口恢复。播放地址与实际 AVPlayer 鉴权兼容性尚未在真实账号和 Apple TV 上验证，遇到错误请查看设置里的脱敏诊断，并记录状态码；403、风控或会员限制不会通过无限重试绕过。

### 媒体库和 TMDB

在设置中配置个人 TMDB Read Token 后，可扫描网盘视频、按文件名识别电影或剧集并搜索 TMDB。低置信度匹配需人工确认。API Token 通过 Keychain 保存；不需要 TMDB 时可先使用文件浏览和播放入口。扫描/海报墙代码尚待 Xcode 与真实媒体库验收。

### 开发者检查

本机若有 Python 3，可运行 `python3 scripts/validate_project.py` 做工程结构检查。它不编译 Swift。Mac 上按 [Mac Codex 交接文档](docs/MAC-CODEX-HANDOFF.md) 运行构建和测试，并把结果写回开发清单与验证报告。

## 运行模式

默认走真实接口。首页点击“生成登录二维码”，使用夸克手机 App 扫码并确认。会话仅保存到 Keychain；接口失败会显示错误，**不会自动回退为 Mock**。

离线检查 UI：在 Xcode > Edit Scheme > Run > Arguments 中添加 `--mock`。Mock 页面持续显示醒目标记，示例文件不属于你的网盘，不能证明真实服务可用。移除该参数后重新运行才回到真实模式。

选择视频会按需获取临时地址并交给 AVPlayer；若接口要求未能由 AVURLAsset 公开选项传递的请求头，播放可能失败并显示诊断。不要把此代码状态理解为已完成真实播放验证。

## 检查与测试

跨平台结构检查（Python 3 标准库，不等于 Swift 编译）：

```sh
python3 scripts/generate_xcode_project.py
python3 scripts/validate_project.py
```

Mac 构建：

```sh
xcodebuild -project QuarkTheater.xcodeproj -scheme QuarkTheater -list
xcodebuild -project QuarkTheater.xcodeproj -scheme QuarkTheater -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcrun simctl list devices available
```

选择本机真实存在的 tvOS Simulator UDID，替换下方占位值后执行：

```sh
xcodebuild -project QuarkTheater.xcodeproj -scheme QuarkTheater -destination 'platform=tvOS Simulator,id=YOUR_SIMULATOR_UDID' CODE_SIGNING_ALLOWED=NO test
```

测试使用合成响应，不携带个人 Cookie，也不执行真实登录。实际测试命令与记录以 [验证报告](docs/VALIDATION.md) 为准。

## 文档

- [开发清单](DEVELOPMENT-CHECKLIST.md)
- [架构说明](docs/ARCHITECTURE.md)
- [API 适配与源码证据](docs/API-ADAPTER.md)
- [Apple TV 安装及验收](docs/APPLE-TV-INSTALL.md)
- [已知问题](docs/KNOWN-ISSUES.md)
- [本轮验证报告](docs/VALIDATION.md)
- [Mac Codex 继续开发交接文档](docs/MAC-CODEX-HANDOFF.md)
- [第三方许可说明](THIRD_PARTY_NOTICES.md)

本项目不依赖 AList、OpenList、WebDAV 或自建视频代理；未复制 Rust 实现。接口来源为第三方开源客户端，并非夸克官方承诺长期兼容的公开 SDK。
