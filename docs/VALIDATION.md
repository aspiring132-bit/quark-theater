# 第一轮验证记录

日期：2026-10-17。验证等级：源码证据、静态工程检查、单元测试运行、真实 API、真机验收分开记录。

## 当前环境

- 开发主机：Windows / PowerShell。
- `Get-Command swift,xcodebuild` 未找到 Swift 编译器或 Xcode；没有可执行的 Apple SDK 编译/签名环境。
- Apple TV 型号、tvOS、Mac/Xcode 尚未提供。最低 tvOS 16.0 仅为源码 API 基线。
- 工程位于 C 盘。默认执行沙箱因扫描已锁定 BitLocker D 盘启动失败；用户授权后改用沙箱外 PowerShell，C 盘文件写入已成功。没有解锁 D 盘或关闭安全设置。
- 本轮最新指令要求完成所有当前可做工作；播放器代码已写，Apple 编译与真机播放仍待 Mac。

## 已核实的外部源码

| 仓库 | 分支 | 固定提交 | 许可证 |
|---|---|---|---|
| lich0821/QuarkPan | master | ca311f6eaf3a50374371ad0e6900d85c992c7788 | MIT |
| niuhuan/quarkpan-rs | main | 41b26b0cd8a03696c4c22bf2c006ad981b6f5d44 | GPL-3.0-only |

协议与许可证原文见 API-ADAPTER.md / THIRD_PARTY_NOTICES.md。Python 参考逻辑移植为原生 Swift，不依赖 Rust FFI。

## 真实网络探测（已执行）

最近一次时间：**2026-10-17 08:57 UTC**；此前 2026-10-16 也完成过匿名探测。

- GET `https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin`
- 参数：`client_id=532`、`v=1.2`、随机 UUID 的 `request_id`。
- HTTP **200**，服务状态 **2000000**。
- 响应包含 `data.members.token`，顶层字段为 `status/message/data`。
- 只记录“token 存在”，**未输出、未保存 token**。
- 没有用户扫码，没有 service ticket 交换，没有登录 Cookie，没有访问个人文件。

脱敏记录：[qr-token-probe.json](evidence/qr-token-probe.json)。

结论仅为“匿名二维码令牌端点可达，返回结构与参考源码一致”。这不是 Swift 客户端联调通过，也不是夸克账号登录成功。

## 静态工程检查（Windows / Python 3，2026-10-17）

执行过：

\`\`\`text
python scripts/generate_xcode_project.py
Generated Xcode project: 27 app and 9 test Swift files.
python scripts/validate_project.py
PASS: 111 PBX objects; references, shared scheme, target settings and generation verified.
Located 53 XCTest methods. Tests NOT executed. Swift/Apple SDK compilation NOT checked.
python -m compileall -q scripts
PASS (exit 0).
\`\`\`

共享 Scheme 默认关闭 \`--mock\`；XCTest App host 用 \`--testing\` 跳过启动时真实会话恢复。Python/工程结构检查不检查 Swift 类型、Apple SDK 可用性或运行时行为。

## 尚未执行

- Xcode build / test / archive。
- XCTest 测试用例运行。
- 真实扫码、凭据交换、会话恢复、根目录及分页。
- 真实下载 URL、Range 和 AVPlayer 验证（实现已写，尚未运行）。
- Apple TV 签名、安装、焦点操作、电视可读性和网络/媒体格式兼容性。

## 下一次必须补齐的记录

在 Mac 记录 Xcode/SDK/Simulator，执行构建与 XCTest，保留完整构建日志（排除个人凭据）。然后记录实际 Apple TV 型号/tvOS、登录及文件浏览用例。播放器已进入代码实现阶段，真实播放验收需在 Mac/Apple TV 完成。

## 2026-10-17 后续实现

- 新增 AVPlayer 播放协调器、临时取址、续播、15 秒进度保存、后台/离开页面保存、历史页、音轨/字幕选择、手动下一集/自动连播设置和有限重试代码。只使用 AVURLAsset 的公开 Cookie/User-Agent 选项；夸克要求的 Origin/Referer 是否必需，需真实设备验证。
- 新增递归分页媒体扫描与 SQLite 快照差异（新增/变更/删除）、电影/剧集文件名解析、TMDB 搜索与匹配评分、用户显式确认、SQLite 匹配/收藏缓存、海报墙/详情/分季分集、媒体库搜索/排序/分类和 Keychain Token 设置。
- 新增网盘搜索接口与界面、账号隔离观看历史界面、首页继续观看入口和设置中的历史/元数据清理操作；登录取消会使会话层的迟到响应失效。
- 最终结构检查通过：27 个 App Swift 文件、9 个测试 Swift 文件、111 个 PBX 对象、53 个 XCTest 方法；Python 脚本 compileall 通过。XCTest 仍未运行，Swift 编译和 Apple SDK 可用性仍需 Mac。
