#!/usr/bin/env python3
"""
Quark Cloud Drive API & Stream Verifier (Standalone Tool)
Use this tool to test Quark QR Login, list cloud drive files, resolve video download URLs,
and verify streaming playback directly on macOS before building the tvOS UI.
"""

import sys
import os
import json
import time
import uuid
import ssl
import webbrowser
import urllib.request
import urllib.parse
import http.cookiejar
from typing import Optional, Dict, Any, List

COOKIE_FILE = os.path.expanduser("~/.quark_theater_session.json")
API_BASE = "https://drive-pc.quark.cn/1/clouddrive"
CLIENT_ID = "532"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"

class QuarkVerifier:
    def __init__(self):
        self.cookie_jar = http.cookiejar.CookieJar()
        self.ssl_context = ssl.create_default_context()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar),
            urllib.request.HTTPSHandler(context=self.ssl_context)
        )
        self.load_session()

    def save_session(self):
        cookies = []
        for c in self.cookie_jar:
            cookies.append({
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "expires": c.expires
            })
        with open(COOKIE_FILE, "w", encoding="utf-8") as f:
            json.dump(cookies, f, indent=2)
        print(f"✅ 会话已保存至: {COOKIE_FILE} (共 {len(cookies)} 个 Cookie)")

    def load_session(self) -> bool:
        if not os.path.exists(COOKIE_FILE):
            return False
        try:
            with open(COOKIE_FILE, "r", encoding="utf-8") as f:
                cookies = json.load(f)
            for item in cookies:
                c = http.cookiejar.Cookie(
                    version=0,
                    name=item["name"],
                    value=item["value"],
                    port=None,
                    port_specified=False,
                    domain=item.get("domain", ".quark.cn"),
                    domain_specified=True,
                    domain_initial_dot=True,
                    path=item.get("path", "/"),
                    path_specified=True,
                    secure=True,
                    expires=item.get("expires"),
                    discard=False,
                    comment=None,
                    comment_url=None,
                    rest={}
                )
                self.cookie_jar.set_cookie(c)
            return True
        except Exception as e:
            print(f"⚠️ 读取保存的会话失败: {e}")
            return False

    def clear_session(self):
        if os.path.exists(COOKIE_FILE):
            os.remove(COOKIE_FILE)
        self.cookie_jar.clear()
        print("🚪 夸克会话已清除，已退出登录。")

    def _request(self, url: str, method: str = "GET", data: Optional[dict] = None, headers: Optional[dict] = None) -> dict:
        req_headers = {
            "User-Agent": USER_AGENT,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Origin": "https://pan.quark.cn",
            "Referer": "https://pan.quark.cn/"
        }
        if headers:
            req_headers.update(headers)

        body = None
        if data is not None:
            body = json.dumps(data).encode("utf-8")
            req_headers["Content-Type"] = "application/json"

        # Ensure all quark cookies are included
        quark_cookies = [f"{c.name}={c.value}" for c in self.cookie_jar if "quark.cn" in c.domain or c.domain == ""]
        if quark_cookies and "Cookie" not in req_headers:
            req_headers["Cookie"] = "; ".join(quark_cookies)

        req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw)
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8")
            raise RuntimeError(f"HTTP {e.code}: {err_body}")

    def login_with_qrcode(self):
        print("\n=== 第一步：获取扫码登录凭证 ===")
        token_url = f"https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id={CLIENT_ID}&v=1.2&request_id={uuid.uuid4()}"
        res = self._request(token_url)
        if res.get("status") != 2000000:
            raise RuntimeError(f"获取二维码 token 失败: {res}")
        token = res["data"]["members"]["token"]
        qr_url = f"https://su.quark.cn/4_eMHBJ?token={token}&client_id={CLIENT_ID}&ssb=weblogin&uc_param_str=&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0"

        try:
            import qrcode
            qr = qrcode.QRCode(box_size=10, border=3)
            qr.add_data(qr_url)
            qr.make(fit=True)
            img = qr.make_image(fill_color="black", back_color="white")
            qr_path = "/Users/wangbin/quark_qr.png"
            img.save(qr_path)
            # Also save to artifact directory for inline preview
            artifact_qr = "/Users/wangbin/.gemini/antigravity/brain/bea6057a-9c9c-48b7-9c0b-dde8249221da/quark_qr.png"
            img.save(artifact_qr)
            print(f"🖼️ 二维码图片已生成: {qr_path}")
            os.system(f'open "{qr_path}"')
            print("📱 正在屏幕上弹窗展示二维码，请使用手机【夸克 App】扫描该二维码：")
            qr.print_ascii(invert=True)
        except Exception as e:
            print(f"⚠️ 生成本地二维码图片失败: {e}")
            print(f"二维码原始数据: {qr_url}")

        print("\n⏳ 正在轮询等待扫码结果 (最长等待 3 分钟)...")
        start_time = time.time()
        ticket = None

        while time.time() - start_time < 180:
            poll_url = f"https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id={CLIENT_ID}&v=1.2&token={token}&request_id={uuid.uuid4()}"
            poll_res = self._request(poll_url)
            status = poll_res.get("status")

            if status == 50004001:
                # Waiting for scan / confirmation
                time.sleep(2)
                continue
            elif status == 2000000 and poll_res.get("message") == "ok":
                ticket = poll_res["data"]["members"]["service_ticket"]
                print("🎉 扫码成功！已获得登录票据。")
                break
            else:
                raise RuntimeError(f"扫码失败或取消: {poll_res}")

        if not ticket:
            raise TimeoutError("扫码登录超时，请重试。")

        # Exchange ticket for session cookies
        info_url = f"https://pan.quark.cn/account/info?st={ticket}&lw=scan"
        info_res = self._request(info_url)
        print(f"👤 用户信息响应: {info_res.get('message', 'ok')}")

        # Normalize cookie domains to .quark.cn
        for c in list(self.cookie_jar):
            if "quark.cn" in c.domain:
                c.domain = ".quark.cn"

        self.save_session()
        print("✅ 登录验证完成，会话已建立！\n")

    def list_files(self, pdir_fid: str = "0", page: int = 1, page_size: int = 50) -> dict:
        t = int(time.time() * 1000)
        query = {
            "pr": "ucpro",
            "fr": "pc",
            "uc_param_str": "",
            "__dt": "1000",
            "__t": str(t),
            "pdir_fid": pdir_fid,
            "_page": str(page),
            "_size": str(page_size),
            "_sort": "file_name:asc"
        }
        url = f"{API_BASE}/file/sort?" + urllib.parse.urlencode(query)
        return self._request(url)

    def get_download_url(self, file_id: str) -> str:
        t = int(time.time() * 1000)
        query = {
            "pr": "ucpro",
            "fr": "pc",
            "uc_param_str": "",
            "__dt": "1000",
            "__t": str(t),
            "sys": "win32",
            "ve": "2.5.56",
            "ut": "",
            "guid": ""
        }
        url = f"{API_BASE}/file/download?" + urllib.parse.urlencode(query)
        res = self._request(url, method="POST", data={"fids": [file_id]})
        if res.get("code") != 0 and res.get("status") != 200:
            raise RuntimeError(f"获取下载链接失败: {res}")
        entries = res.get("data", [])
        for item in entries:
            if item.get("fid") == file_id:
                return item["download_url"]
        raise RuntimeError(f"响应中未找到文件 {file_id} 的 download_url")

    def test_stream_playback(self, download_url: str):
        print("\n=== 测试播放流可用性 (HTTP Range 206) ===")
        # Test if CDN requires Referer/Origin or accepts raw requests
        print("1. 测试不带 Referer 头的 Range 请求 (模拟系统原生播放器 AVPlayer)...")
        headers = {
            "User-Agent": USER_AGENT,
            "Range": "bytes=0-1024"
        }
        req = urllib.request.Request(download_url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                print(f"   👉 状态码: {resp.status} (206 = 完美支持原生分段流式播放)")
                print(f"   👉 Content-Type: {resp.headers.get('Content-Type')}")
                print(f"   👉 Content-Length: {resp.headers.get('Content-Length')} 字节")
                print("   ✅ 原生播放器无需特殊 Header 即可直接拉流！")
        except urllib.error.HTTPError as e:
            print(f"   ⚠️ 失败: HTTP {e.code}")
            print("2. 测试带夸克 Referer/Origin 的 Range 请求...")
            headers["Referer"] = "https://pan.quark.cn/"
            headers["Origin"] = "https://pan.quark.cn"
            req2 = urllib.request.Request(download_url, headers=headers)
            try:
                with urllib.request.urlopen(req2, timeout=15) as resp:
                    print(f"   👉 状态码: {resp.status}")
                    print("   ℹ️ 此文件 CDN 限制了 Referer，需要自定义请求头。")
            except Exception as e2:
                print(f"   ❌ 带 Header 请求也失败: {e2}")

        print("\n🎬 是否要在本地使用 QuickTime 或系统默认播放器打开试播？")
        print(f"播放地址: {download_url[:120]}...")
        cmd = f'open "{download_url}"'
        print(f"👉 运行命令即可试播: {cmd}")
        os.system(cmd)


def main():
    verifier = QuarkVerifier()

    if "--logout" in sys.argv:
        verifier.clear_session()
        return

    # Check if we have valid cookies
    has_cookies = any("quark.cn" in c.domain for c in verifier.cookie_jar)
    if not has_cookies or "--login" in sys.argv:
        print("🔑 当前未检测到已保存的夸克会话，开始扫码登录...")
        verifier.login_with_qrcode()

    # List files
    current_pdir = "0"
    current_name = "我的网盘根目录"

    while True:
        print(f"\n📁 正在读取目录: [{current_name}] (ID: {current_pdir})...")
        try:
            res = verifier.list_files(pdir_fid=current_pdir)
        except Exception as e:
            print(f"❌ 读取文件列表失败: {e}")
            print("💡 如果提示 401 或认证失败，请加 --login 参数重新扫码登录：python3 scripts/quark_stream_verifier.py --login")
            break

        data = res.get("data", {})
        file_list = data.get("list", [])
        total = res.get("metadata", {}).get("_total", len(file_list))

        print(f"📊 找到 {len(file_list)} 个项目 (总计 {total}):")
        print("-" * 75)
        print(f"{'序号':<5} {'类型':<8} {'大小':<12} {'文件名'}")
        print("-" * 75)

        for i, f in enumerate(file_list):
            is_dir = f.get("dir", False) or f.get("file_type") == 0
            kind = "📁 文件夹" if is_dir else "🎬 视频" if f.get("file_name", "").lower().endswith((".mp4", ".mkv", ".mov", ".m4v", ".ts")) else "📄 文件"
            size_mb = f"{f.get('size', 0) / (1024*1024):.1f} MB" if not is_dir else "-"
            print(f"[{i+1:>2}]  {kind:<8} {size_mb:<12} {f.get('file_name')}")

        if not file_list:
            print("（此目录下没有文件）")

        print("-" * 75)
        print("💡 操作提示:")
        print("  - 输入数字序号: 进入文件夹 或 播放该视频")
        print("  - 输入 '0': 返回根目录")
        print("  - 输入 'r': 刷新当前目录")
        print("  - 输入 'q': 退出")
        print("  - 输入 'logout': 退出登录并清除 Cookie")

        try:
            choice = input("\n请选择操作 > ").strip().lower()
        except EOFError:
            print("\n🤖 [自动化模式] 检测到后台终端运行，正在自动查找视频并测试播放流...")
            video_item = next((f for f in file_list if not (f.get("dir", False) or f.get("file_type") == 0) and f.get("file_name", "").lower().endswith((".mp4", ".mkv", ".mov", ".m4v", ".ts", ".webm"))), None)
            if video_item:
                fid = video_item["fid"]
                name = video_item.get("file_name", fid)
                print(f"🎬 自动选中视频文件【{name}】进行流式播放测试...")
                try:
                    dl_url = verifier.get_download_url(fid)
                    print(f"✅ 成功获得播放地址: {dl_url[:100]}...")
                    verifier.test_stream_playback(dl_url)
                except Exception as e:
                    print(f"❌ 解析播放流失败: {e}")
                break
            else:
                first_dir = next((f for f in file_list if f.get("dir", False) or f.get("file_type") == 0), None)
                if first_dir and current_pdir == "0":
                    current_pdir = first_dir["fid"]
                    current_name = first_dir.get("file_name", first_dir["fid"])
                    print(f"📁 根目录下未见视频文件，自动进入首个文件夹【{current_name}】查找...")
                    continue
                else:
                    print("🏁 根目录下未发现可自动播放的视频文件，列表展示完毕。")
                    break

        if choice in ("q", "quit", "exit"):
            break
        elif choice == "logout":
            verifier.clear_session()
            break
        elif choice == "r":
            continue
        elif choice == "0":
            current_pdir = "0"
            current_name = "我的网盘根目录"
        elif choice.isdigit():
            idx = int(choice) - 1
            if 0 <= idx < len(file_list):
                target = file_list[idx]
                is_dir = target.get("dir", False) or target.get("file_type") == 0
                if is_dir:
                    current_pdir = target["fid"]
                    current_name = target.get("file_name", target["fid"])
                else:
                    # Video or file playback test
                    fid = target["fid"]
                    name = target.get("file_name", fid)
                    print(f"\n🚀 正在为【{name}】解析播放流下载地址...")
                    try:
                        dl_url = verifier.get_download_url(fid)
                        print(f"✅ 成功获得播放地址: {dl_url[:100]}...")
                        verifier.test_stream_playback(dl_url)
                    except Exception as e:
                        print(f"❌ 解析失败: {e}")
            else:
                print("⚠️ 序号超出范围，请重试。")
        else:
            print("⚠️ 无效输入，请重试。")

if __name__ == "__main__":
    main()
