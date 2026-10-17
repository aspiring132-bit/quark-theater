# Apple TV 构建与安装

**当前没有已编译或已签名安装包。** 本次开发主机为 Windows；以下是待在 Mac 执行的步骤，不是已完成的验证记录。

## 先确认设备

记录 Apple TV 的型号和当前 tvOS，以及 Mac 的 macOS/Xcode 版本。可在 Apple TV“设置 > 通用 > 关于本机”查看设备信息。工程暂用 tvOS 16.0 API 基线；只有确认设备系统和 Xcode 支持范围后才能确定最终最低版本。

Apple 官方参考：[设备型号](https://support.apple.com/guide/tv/which-apple-tv-model-do-i-have-atvbac878c90/tvos)、[Xcode 系统与 SDK 要求](https://developer.apple.com/xcode/system-requirements/)、[在设备运行 App](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)。

## 模拟器编译与测试

1. 在 Mac 安装支持目标 tvOS 的 Xcode，并安装相应 tvOS SDK/Simulator runtime。
2. 复制整个项目目录，打开 `QuarkTheater.xcodeproj`。
3. Scheme 选 QuarkTheater，目标选本机已安装的 tvOS Simulator。
4. 执行 Product > Build，再执行 Product > Test。
5. 要检查离线 UI，在 Edit Scheme > Run > Arguments 添加 `--mock`。该参数默认不开启。移除后重启才能验证真实接口。

可复现命令见 README；终端先运行 `xcodebuild -version`、`xcodebuild -showdestinations -project QuarkTheater.xcodeproj -scheme QuarkTheater`，不要照抄不存在的机型名称。

## 真机配对与签名

1. Mac 与 Apple TV 接入可以互相发现的网络。
2. 在 Apple TV 打开“设置 > 遥控器与设备 > 远程 App 与设备”，按所用 Xcode 版本的设备管理界面配对。
3. 在 Xcode 的设备管理窗口选择 Apple TV，按屏幕提示完成配对和信任；新旧 Xcode 的菜单名称可能不同。
4. 在 App target 的 Signing & Capabilities 中选择自己的 Development Team，使用唯一 Bundle Identifier，启用自动签名。
5. 选择配对的 Apple TV 为运行目标，Build/Run。设备首次开发运行如要求额外确认，按 Xcode/设备提示处理。
6. 保存签名、安装结果及错误信息；不要将证书、描述文件或账号凭据提交到代码仓库。

个人签名和不同分发方式的权限/有效期由所用开发者账号决定；本轮没有替用户注册设备或发布到 App Store/TestFlight。

## 第一轮验收

- 真模式生成二维码；手机扫码确认；取消后不继续登录；过期后可重新生成。
- 读取根目录和子目录；测试超过 50 项的目录翻页；上级/刷新后状态正确。
- 强制退出并重新打开 App，核实 Keychain 恢复；退出登录后不能继续读原账号。
- 启用 Mock 时标识持续可见；切回真模式不能显示 Mock 文件。
- 使用 Siri Remote 检查焦点、滚动和返回；检查二维码是否可扫描。
- 播放器代码已接入。需在真机验证登录、下载地址请求头、播放、seek、后台进度保存和历史恢复后，才可以标记播放通过。

将结果写入 `docs/VALIDATION.md` 和开发清单，包含日期、Xcode、机型、tvOS、用例和结果。日志只保留状态码与脱敏事件。
