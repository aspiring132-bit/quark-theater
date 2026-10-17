# Quark API 适配说明

核查日期：2026-10-16。以下内容来自第三方开源客户端的固定提交，不是夸克公开稳定 API 承诺。

## 仓库和来源

| 仓库 | 默认分支 | 核查时 HEAD | 提交时间 UTC | 许可证 |
|---|---|---|---|---|
| [lich0821/QuarkPan](https://github.com/lich0821/QuarkPan) | master | ca311f6eaf3a50374371ad0e6900d85c992c7788 | 2025-11-29 13:16:17 | MIT |
| [niuhuan/quarkpan-rs](https://github.com/niuhuan/quarkpan-rs) | main | 41b26b0cd8a03696c4c22bf2c006ad981b6f5d44 | 2026-03-18 09:13:58 | GPL-3.0-only |

两个公开、未归档仓库已通过 GitHub 元数据与固定提交源码核查。Python 项目是 Swift 原生适配的主要协议依据，并保留其 MIT notice。Rust 项目只用于交叉核对，不引入依赖、不复制实现、不使用 FFI。

固定源码：

- [Python 二维码和 Cookie 交换](https://github.com/lich0821/QuarkPan/blob/ca311f6eaf3a50374371ad0e6900d85c992c7788/quark_client/auth/api_login.py)：get_qr_code、_build_qr_url、check_login_status、_get_user_info_and_cookies。
- [Python 默认 API 参数和请求头](https://github.com/lich0821/QuarkPan/blob/ca311f6eaf3a50374371ad0e6900d85c992c7788/quark_client/config.py)。
- [Python HTTP 客户端](https://github.com/lich0821/QuarkPan/blob/ca311f6eaf3a50374371ad0e6900d85c992c7788/quark_client/core/api_client.py)。
- [Python 文件列表和搜索](https://github.com/lich0821/QuarkPan/blob/ca311f6eaf3a50374371ad0e6900d85c992c7788/quark_client/services/file_service.py)。
- [Python 下载地址和请求头](https://github.com/lich0821/QuarkPan/blob/ca311f6eaf3a50374371ad0e6900d85c992c7788/quark_client/services/file_download_service.py)。
- [Python Cookie 存储实现](https://github.com/lich0821/QuarkPan/blob/ca311f6eaf3a50374371ad0e6900d85c992c7788/quark_client/auth/login.py)。
- [Rust Cookie、下载和列表分页](https://github.com/niuhuan/quarkpan-rs/blob/41b26b0cd8a03696c4c22bf2c006ad981b6f5d44/libquarkpan/src/api.rs)。
- [Rust 文件及分页字段模型](https://github.com/niuhuan/quarkpan-rs/blob/41b26b0cd8a03696c4c22bf2c006ad981b6f5d44/libquarkpan/src/model.rs)。

## 二维码登录

1. GET `https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin`，参数 `client_id=532`、`v=1.2`、`request_id=<UUID>`。要求 `status=2000000` 和 `data.members.token`。
2. 二维码 URL 为 `https://su.quark.cn/4_eMHBJ`，参数 `token`、`client_id=532`、`ssb=weblogin`、空 `uc_param_str` 和 `uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0`。Swift 通过 URLComponents 编码。
3. GET `https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken`，登录参数相同并加 token。状态 `50004001` 表示等待；成功需 `status=2000000`、`message=ok` 和非空 `data.members.service_ticket`。
4. GET `https://pan.quark.cn/account/info?st=<ticket>&lw=scan`，从响应 Set-Cookie 建立会话。源码没有核实稳定服务端用户 ID 或昵称字段，不臆造这些 JSON 字段。
5. Swift 再取根目录一条记录验证 Cookie 确实能访问网盘，成功后才建立 Account 并保存 Keychain。ticket 本身不代表登录完成。

参考实现把 50004002、50004003、50004004 均视为失败，却没有分别说明其含义；本应用保留业务错误码，不自行命名为取消/过期。UI 的 300 秒只是本地等待上限，不冒充服务器二维码有效期。

## 会话与账号隔离

使用禁用共享 Cookie storage 和磁盘缓存的 ephemeral URLSession。完整 Cookie 属性与 Account 一起保存到 Keychain，访问级别为 WhenUnlockedThisDeviceOnly。发送时按域、路径、Secure 和 expiresDate 筛选，合并服务端新 Set-Cookie；不向任意 CDN 复制整份 Cookie。

Python 登录模块实际将 Cookie 写入 JSON，并在没有 expires 属性时按 7 天处理；这不是经证实的夸克有效期，本应用不采用该假设。Rust 源码有 Cookie 更新逻辑，但未提供可验证 refresh-token API。

每次成功新登录生成本地 UUID accountId；恢复同一份凭据时沿用它。没有证据证明 __uid 跨重新登录稳定，因此不把它当长期账号主键。重新扫码可能产生新本地分区；以后发现可靠服务端 ID 再评估迁移。登录前没有从用户取得 Cookie，不在源码中写入账号 Cookie。

恢复时验证根目录请求。401 清除过期的本地凭据；403/429 不视为过期、不清凭据、不自动重试。退出登录清除本地 Keychain 会话。

## 文件列表、ID 和分页

GET `https://drive-pc.quark.cn/1/clouddrive/file/sort`。

公共参数：`pr=ucpro`、`fr=pc`、空 `uc_param_str`、`__t=<Unix 毫秒时间戳>`、`__dt=1000`。目录参数：`pdir_fid=<父目录 ID>`、`_page=<从 1 开始>`、`_size=<1…100>`、`_sort=file_name:asc`。根目录 ID 为字符串 `0`。

响应必须包含 `status=200`、若存在则 `code=0`，及 `data.list`。文件字段 `fid`、`pdir_fid`、`file_name`、`size`、`updated_at`、`dir` 按源码映射；Python 还通过 `file_type==0` 判断目录。Rust 明确有 `metadata._total/_count/_page`。若总数缺失，客户端按当前页是否满页续取，并在空页停止，不把返回条数误当成请求页长。

Swift 做秒/毫秒级别的防御性时间戳转换；真实账号的 updated_at 样本尚未取得，时间语义待联调。必要字段缺失时返回明确错误，不填入 Mock 文件。

夸克 Python 默认文件请求使用 QQBrowser/Chrome 94 User-Agent；其二维码登录客户端单独使用 macOS Chrome 139 User-Agent，并加 Cache-Control/Pragma no-cache。Swift 对 uop.quark.cn 和 pan.quark.cn 使用登录 UA，其余接口沿用文件 API UA。是否所有这些头对真实二维码登录都必需仍待账号联调。Origin `https://pan.quark.cn`、Referer `https://pan.quark.cn/`、Accept 和 Accept-Language；JSON 请求设置 Content-Type。Cookie 只发送给匹配域/路径。请求超时 30 秒、资源超时 45 秒。

## 搜索

Python 源码在同一文件 API 基址调用 GET `/file/search`，参数含 `q`、`_page`、`_size`、`_fetch_total=1`、`_sort=file_type:desc,updated_at:desc`、`_is_hl=1` 及公共参数。其 `folder_id` 参数被忽略，因此不能声称目录范围搜索。Swift 已适配此接口和文件浏览搜索框；真实账号结果仍待验证。

## TMDB

Swift 使用 TMDB 官方 v3 `/search/movie` 或 `/search/tv`，通过用户提供的 v4 Read Access Token 设置 Bearer Authorization；Token 单独存入 Keychain。TMDB 返回的标题、年份、简介、海报/背景路径、评分和类型 ID 只作为候选。匹配评分仅用于排序；用户明确选择并确认后，结果才写入 `MediaCatalogRepository`。海报路径按 TMDB 图像基础 URL 规则构建；当前没有磁盘图像缓存、演员详情或评分类型本地化。参考：[TMDB Movie Search](https://developer.themoviedb.org/reference/search-movie)、[TMDB TV Search](https://developer.themoviedb.org/reference/search-tv)、[图像 URL 规则](https://developer.themoviedb.org/docs/image-basics)。

## 下载地址及播放器边界

POST `https://drive-pc.quark.cn/1/clouddrive/file/download`，公共参数另加 `sys=win32`、`ve=2.5.56`、空 `ut` 和 `guid`，JSON 正文 `{"fids":["<fileID>"]}`。响应 `data` 是数组；必须取 fid 匹配项的 `download_url`。只接受 HTTPS 地址且只按需获取。参考 JSON 没有可确认的 expiresAt 字段，所以返回 nil，不猜 TTL。

所核查项目没有可移植的 HLS/转码/专用 video-play 接口。Rust 下载流还传 Cookie、Origin、Referer、UA，并用 HTTP Range/206 恢复下载；Python 下载代码也设置下载请求头。所以获得 URL 不能证明 AVPlayer 可播。Swift 已实现按需取址和 AVPlayer/PlaybackCoordinator 代码，但没有真实下载 URL 或播放验证。

Apple 公共 API 支持 [AVURLAssetHTTPCookiesKey](https://developer.apple.com/documentation/avfoundation/avurlassethttpcookieskey) 和 [AVURLAssetHTTPUserAgentKey](https://developer.apple.com/documentation/avfoundation/avurlassethttpuseragentkey)，但任意 Referer/Origin 头没有可用的通用公开键；不使用未支持的 AVURLAssetHTTPHeaderFieldsKey。当前 PlaybackCoordinator 已实现，使用公开 Cookie/UA 选项。夸克当前下发 Origin/Referer，AVPlayer 可能因此无法播放；代码会记录限制，不会伪装成功。需要真实链接和 Apple TV 验证是否服务端实际强制这些头。

重定向：QuarkPan QR 登录用的 httpx 客户端未启用 follow_redirects（默认关闭），account/info 检查要求 HTTP 200。对这几个 QR 步骤，本 Swift transport 拒绝重定向与核实实现一致；目前没有 account/info 必须 302 的证据。Python 文件 API 客户端启用 follow_redirects，因此如果真实列表端点发生重定向，本客户端目前会明确报错，须在验证域名、Cookie 范围后再加入允许列表。

## 错误与风控

401、403、429 有单独用户提示；只有指定的瞬时网络错误和 5xx 可有限退避。403 可能是权限、会员或风控问题，不能断言 Cookie 已过期。429 要求等待。失败不静默换为 Mock；诊断不存 Cookie、ticket、二维码令牌或完整带签名地址。

## 当前验证记录

2026-10-17 08:57 UTC，根线程再次对匿名 QR token 端点进行 HTTPS 探测：HTTP 200、`status=2000000`、`data.members.token` 存在。此前 2026-10-16 也完成同一探测。探测未输出或保存 token，未扫码、未建立会话或访问个人文件。脱敏证据：[qr-token-probe.json](evidence/qr-token-probe.json)。

这是端点可达性证据，不是 Swift 适配器或真实账号验收。Mock / QuarkClientTests 使用合成数据，不代表真实 API 实测；Xcode、XCTest、下载流及 Apple TV 均尚未运行/验证。
