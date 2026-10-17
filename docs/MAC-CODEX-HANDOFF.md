# Quark Theater：Mac Codex 继续开发交接

这份文档供下一位在 Mac 上运行的 Codex 直接接手。目标是继续当前工程并完成 Apple 平台验证，不要重新生成一个替代项目，也不要把尚未验证的代码描述为可用。

## 项目位置和获取

GitHub 仓库：`https://github.com/aspiring132-bit/quark-theater`（预期为私有仓库）。

在 Mac 上克隆后进入仓库目录：

```sh
git clone https://github.com/aspiring132-bit/quark-theater.git
cd quark-theater
```

用 Xcode 打开 `QuarkTheater.xcodeproj`。项目使用原生 Xcode 工程和 shared scheme，没有 Swift Package 第三方依赖；跨平台工程结构由 Python 脚本校验。

## 当前状态和边界

- tvOS SwiftUI App、共享 Scheme、XCTest target、服务层、SQLite 历史仓库和播放协调器已经写入仓库。
- Windows 上运行 `python scripts/validate_project.py` 通过：111 个 PBX 对象、27 个 App Swift 文件、9 个测试 Swift 文件、53 个 XCTest 方法。
- 上述检查不等于 Swift 编译。当前还没有 Xcode build、XCTest、Simulator 或 Apple TV 安装结果。
- 夸克二维码匿名令牌端点曾返回 HTTP 200，但没有用户扫码、账号 Cookie 或个人文件访问证据。
- 播放器会按需请求下载 URL，并将 Cookie/User-Agent 交给 AVURLAsset；所需 Origin/Referer 等通用请求头能否满足夸克 CDN 要求仍未知。真实下载 URL、Range、重定向、格式兼容和 AVPlayer 播放都未验证。
- 不依赖 AList、OpenList、WebDAV 或自建代理；不把短期播放 URL 存入媒体库；不要在日志、提交、测试夹具或聊天中暴露用户 Cookie、二维码 token、TMDB Token。
- 若遇到 401/403/429、风控、会员权限或未知响应，应记录脱敏错误并停止，不要伪造成功或无限重试。

## 接手后按顺序执行

1. 查看 `DEVELOPMENT-CHECKLIST.md`、`docs/VALIDATION.md`、`docs/KNOWN-ISSUES.md`、`docs/API-ADAPTER.md` 和本文件，再检查 `git status`。保留用户已有改动。
2. 记录 `sw_vers`、`xcodebuild -version`、`xcodebuild -showsdks`，确认已安装 tvOS Simulator runtime。核对 Apple TV 型号和 tvOS（若当前可连接）；不要从部署目标推断设备型号。
3. 运行工程检查和 Xcode build：

   ```sh
   python3 scripts/validate_project.py
   bash scripts/verify-macos.sh
   ```

   修复所有编译/链接错误，重跑构建。若部署目标与当前 Xcode 或用户设备不兼容，先根据实际 API 和设备调整，再记录理由。

4. 列出可用 Simulator 并执行完整 XCTest：

   ```sh
   xcrun simctl list devices available
   bash scripts/verify-macos.sh YOUR_TVOS_SIMULATOR_UDID
   ```

   保存 `.xcresult` 位置和测试摘要；不提交 DerivedData、xcresult 或本机日志。

5. 在 Simulator 检查启动、导航、中文可读性、焦点移动、Mock 标记、错误提示。Mock 仅验证 UI；绝不可据此宣称真实 API 通了。
6. 连接用户自己的 Apple TV 后，按 `docs/APPLE-TV-INSTALL.md` 配对、选择个人 Development Team、设置唯一 Bundle Identifier 并安装。真实账号扫码由用户本人在手机上确认。先验登录、会话恢复、根目录/子目录分页，再取一个用户选定视频做播放验证。
7. 播放验证按层拆开记录：取址 API 状态与脱敏字段；Range 探测状态/Content-Range/Content-Type；是否发生重定向及目标 host；AVPlayer 首帧、音频、seek、字幕/音轨、后台保存和恢复。不要保存完整签名 URL、查询 token 或 Cookie。若 AVPlayer 无法传递必需请求头，保留错误证据并评估公开、合规的替代方案；不要先搭建代理。
8. 每验证一项，更新 `DEVELOPMENT-CHECKLIST.md` 中状态和证据；同步 `docs/VALIDATION.md` 与 `docs/KNOWN-ISSUES.md`。严格区分“源码实现”“模拟器/测试通过”“真实 API”“Apple TV 通过”。

## 用户如何运行

- 离线看界面：Scheme Run Arguments 添加 `--mock`，页面应持续显示 Mock 标识。
- 真实账号：移除 `--mock`，运行 App，生成二维码，用夸克手机 App 扫码并确认。
- 文件浏览：从首页进入网盘入口，打开目录、分页或搜索。
- 播放/续播：选视频进入播放器；历史保存在当前设备本地。若播放失败，保留脱敏诊断，不要将错误重试成功当作 API 兼容证明。
- TMDB：在设置填写 Read Token，由 Keychain 保存；不要把 Token 写进 xcconfig、源码或 Git。

## 完成后交付

在 `docs/VALIDATION.md` 写明 Mac/Xcode/tvOS/设备信息、构建命令和结果、测试通过数、登录与播放各阶段结果、未完成项。开发清单只把有证据通过的事项改成“已完成”。最终说明哪些功能在 Simulator 验证，哪些在真实 Apple TV 和真实夸克账号验证，哪些仍受请求头/格式/服务端限制阻塞。
