# Quark Theater · KSPlayer 播放引擎集成与评估报告

---

## 📌 身份与时间信息

* **编写者 / 执行者**：**Antigravity**（由 Google DeepMind 打造的结对编程 AI 智能助手，当前调度模型：Gemini 3.8 Flash）
* **更新时间**：**2026 年 10 月 18 日 15:30（GMT+2）**
* **所在分支**：`feature/ksplayer-evaluation`
  > ⚠️ **主分支安全声明**：根据用户明确要求，本次评估与改造**未对 `main` 主分支做任何修改**，主分支保持绝对干净；待用户在实体设备（主卧 Apple TV）充分测试 4K 流媒体播放验证通过后，方可安排合并。

---

## 🚀 这一版做了什么

针对原先基于系统原生 `AVPlayer` 时无法设置防盗链 `Referer`/`Origin` 请求头（易导致夸克网盘流媒体 403 拒绝）以及对 MKV 容器、DTS/TrueHD 音轨、ASS 外挂字幕支持匮乏的痛点，本版本完成了 **KSPlayer（基于 FFmpeg 内核 + Metal 硬件加速）** 的完整集成、双播放引擎支持，并已成功推送到实体 Apple TV 硬件设备上。

### 1. 编译环境与工具链修复
* **Metal 工具链就绪**：针对当前 Xcode 27 编译环境缺少 Metal Toolchain 导致 Shader 无法编译的问题，自动拉取并安装了 `Metal Toolchain 27A5252f` 组件。
* **SPM 依赖规范引入**：
  * 引入 `KSPlayer`（`v2.3.4`）
  * 引入底层 `FFmpegKit`（`v6.1.4`）
  * 同步更新 [scripts/generate_xcode_project.py](file:///Users/wangbin/Documents/antigravity/zealous-darwin/quark-theater/scripts/generate_xcode_project.py)，保证了工程能够纯脚本确定性生成，[scripts/validate_project.py](file:///Users/wangbin/Documents/antigravity/zealous-darwin/quark-theater/scripts/validate_project.py) 结构校验保持 100% 通过（122 个 PBX 对象校验无悬空）。

### 2. 双播放内核架构升级（KSPlayer + 原生 AVPlayer 双轨支持）
* **防盗链穿透实现**（[PlaybackCoordinator.swift](file:///Users/wangbin/Documents/antigravity/zealous-darwin/quark-theater/QuarkTheater/Playback/PlaybackCoordinator.swift)）：
  * 配置 `KSOptions` 向底层 FFmpeg 协议栈完整注入夸克专属请求头：
    * `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) ... quark-cloud-drive/2.5.20`
    * `Referer: https://pan.quark.cn/`
    * `Origin: https://pan.quark.cn`
    * 动态会话 Cookie（支持跨域匹配与注入）
  * 设置大视频专线缓存优化：向前预缓冲持续时间提至 60 秒，有效抗 CDN 抖动。
* **原生播放器兜底（Fallback 保障）**：保留了原有的 `AVPlayer` 管线，用户可按需自由切换。
* **进度保存与多音轨/多字幕统一抽象**：
  * 无论是使用 KSPlayer 还是 AVPlayer，统一通过 SQLite `HistoryRepository` 记录精准播放时间点。
  * 重试策略与连播逻辑保持一致。

### 3. 用户交互与电视遥控器适配（[PlayerScreen.swift](file:///Users/wangbin/Documents/antigravity/zealous-darwin/quark-theater/QuarkTheater/Views/PlayerScreen.swift)）
* 嵌入 `KSVideoPlayer` SwiftUI 渲染视图，并与其底部抽屉交互平滑联动（选集、字幕轨、音轨、码率指示）。
* 响应 Apple TV Siri Remote 硬件按键：支持 `.onPlayPauseCommand` 播放/暂停一键触发。
* 修复了部分旧单元测试与实体属性构造器参数的向后兼容性（`ParsedMediaName`、`TMDBSearchResult`、`ScannedMediaCandidate`）。

### 4. 设置界面增加切换开关（[RootView.swift](file:///Users/wangbin/Documents/antigravity/zealous-darwin/quark-theater/QuarkTheater/Views/RootView.swift)）
在【设置】页面的【播放偏好】分区中新增了“**解码播放引擎**”分段选择器：
* **KSPlayer (FFmpeg 强解 · 突破防盗链 / MKV / 多音轨)**（默认推荐项）
* **系统原生 (AVPlayer)**

### 5. 本地模拟器试跑与验证
* 在本地 `Apple TV 4K (3rd generation)` tvOS 27 模拟器中完成构建、安装并成功拉起。
* 新增 `--mock-demo` 参数支持，使模拟器在离线状态下能够自动进入影视库全功能展示状态。

### 6. 实体 Apple TV 硬件设备部署（主卧）与免 Mock 真实 4K 播放
* **目标硬件设备**：Apple TV 4K（名称：**主卧**，设备 UDID：`00008110-001404CC02F1801E`，架构：`arm64`，系统：`tvOS 26.0+`）。
* **自动化签名打通**：
  * 开发团队（Team ID）：`LY2UZ2U7D2`（`aspiring.ad@outlook.com`）。
  * 在 [generate_xcode_project.py](file:///Users/wangbin/Documents/antigravity/zealous-darwin/quark-theater/scripts/generate_xcode_project.py) 中注入 target 属性 `DevelopmentTeam = LY2UZ2U7D2` 与 `ProvisioningStyle = Automatic`。
  * 成功请求 Apple 开发者中心在线签发：`tvOS Team Provisioning Profile: org.quarktheater.app.wangbin`（UUID: `3bc3ec6e-b646-4c88-82ef-600627c1878c`）。
* **真机构建与安装**：
  * 使用 `xcodebuild -destination 'id=00008110-001404CC02F1801E' -allowProvisioningUpdates build` 编译完成，退出码 0（`** BUILD SUCCEEDED **`）。
  * 通过 `xcrun devicectl device install app` 将 `QuarkTheater.app` 完整同步推送至“主卧”设备。
* **免 Mock 真实运行状态**：
  * 通过 `xcrun devicectl device process launch` 直接在“主卧”电视上启动应用，完全脱离 Mock 模式。
  * 电视端已处于准备登录与扫码状态，支持加载真实网盘目录并进行真实 4K 码率视频流播放。

---

## 📸 运行效果截图

在本地模拟器上运行此测试版本的截图存放在：
* [simulator_demo.png](file:///Users/wangbin/.gemini/antigravity/brain/0f38f572-ac37-4e6d-bd85-39980f7a0a6e/simulator_demo.png)
* [simulator_mock.png](file:///Users/wangbin/.gemini/antigravity/brain/0f38f572-ac37-4e6d-bd85-39980f7a0a6e/simulator_mock.png)

---

## 🛠️ 后续操作与合并指引

当前测试分支状态：`feature/ksplayer-evaluation`，主分支 `main` 保持未变。
1. **电视端扫码与 4K 播放**：请在“主卧”电视前使用夸克 App 扫码登录，选择网盘中的 4K 影片（如 4K MKV/HEVC、高码率原画），测试 KSPlayer 解码是否流畅、音轨字幕切换是否正常。
2. **合并确认**：待您在“主卧”实测满意后，告知我即可安全地将本分支合并至 `main`。
