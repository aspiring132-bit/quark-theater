#!/usr/bin/env python3
"""Reproducible host smoke test for the loopback VLC origin/HLS proxy."""
import http.server, pathlib, subprocess, tempfile, threading

class Handler(http.server.BaseHTTPRequestHandler):
    port = 0
    def do_GET(self):
        if self.path == "/master.m3u8":
            p = str(Handler.port)
            lines = [
                '#EXTM3U',
                f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="http://127.0.0.1:{p}/audio.m3u8?token=abcdefghijklmnopqrstuvwxyz0123456789&sig=9876543210zyxwvutsrqponmlkjihgfedcba",FOO="bar",URI="http://127.0.0.1:{p}/alt-audio.m3u8?secret=supersecretlongtokenstringhere"',
                '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"',
                '#EXT-X-MAP:URI="init.mp4"',
            ]
            for i in range(513): lines.extend(['#EXTINF:4,', f'segment-{i}.ts'])
            body = ('\n'.join(lines) + '\n').encode()
            self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        body = b"0123456789abcdef"
        value = self.headers.get("Range", "")
        if value == "bytes=4-9": body, status = body[4:10], 206
        else: status = 200
        self.send_response(status)
        if status == 206: self.send_header("Content-Range", "bytes 4-9/16")
        self.send_header("Content-Length", str(len(body))); self.send_header("Content-Type", "video/mp4"); self.end_headers(); self.wfile.write(body)
    def do_HEAD(self):
        self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.end_headers()
    def log_message(self, *_): pass

HARNESS = r'''
import Foundation
struct PlaybackResource { let fileID:String; let url:URL; let cookies:[HTTPCookie]; let requiredHTTPHeaders:[String:String]; let expiresAt:Date? }
enum PlaybackProbe { static func applicableCookies(_ c:[HTTPCookie], url:URL)->[HTTPCookie] { c } }
@main struct Main { static func main() async throws {
 let r=PlaybackResource(fileID:"test",url:URL(string:"http://127.0.0.1:PORT/master.m3u8")!,cookies:[],requiredHTTPHeaders:["Origin":"https://pan.quark.cn"],expiresAt:nil)
 let p=VLCOriginHTTPProxy(resource:r,allowLoopbackForTesting:true); let u=try await p.start()
 let (playlist,_)=try await URLSession.shared.data(from:u); let s=String(data:playlist,encoding:.utf8)!
 guard s.contains("#EXT-X-KEY"), s.components(separatedBy:"127.0.0.1").count > 513 else { throw NSError(domain:"h",code:1) }
 guard !s.contains("token=abcdefghijklmnopqrstuvwxyz0123456789"), !s.contains("secret=supersecretlongtokenstringhere"), !s.contains("/audio.m3u8"), !s.contains("/alt-audio.m3u8") else { throw NSError(domain:"h",code:10) }
 for line in s.components(separatedBy:.newlines) where line.contains("#EXT-X-MEDIA") {
     guard line.contains("URI=\"http://127.0.0.1:"), !line.contains("?token="), !line.contains("?secret=") else { throw NSError(domain:"h",code:11) }
     let uriMatches = line.components(separatedBy:"URI=\"").dropFirst()
     guard uriMatches.count == 2 else { throw NSError(domain:"h",code:12) }
     for match in uriMatches {
         guard let quoteIdx = match.firstIndex(of:"\"") else { throw NSError(domain:"h",code:13) }
         let uriVal = String(match[..<quoteIdx])
         guard uriVal.hasPrefix("http://127.0.0.1:"), !uriVal.contains("?"), !uriVal.contains("token"), !uriVal.contains("secret") else { throw NSError(domain:"h",code:14) }
     }
 }
 var h=URLRequest(url:u); h.httpMethod="HEAD"; let (hd,hr)=try await URLSession.shared.data(for:h); guard (hr as! HTTPURLResponse).statusCode==200,hd.isEmpty else {throw NSError(domain:"h",code:2)}
 let segLine = s.components(separatedBy:.newlines).first { $0.hasPrefix("http") && $0.contains("127.0.0.1") }!
 let segURL = URL(string: segLine)!
 var q=URLRequest(url:segURL); q.httpMethod="GET"; q.setValue("bytes=4-9",forHTTPHeaderField:"Range"); let (b,br)=try await URLSession.shared.data(for:q)
 let httpRes = br as! HTTPURLResponse
 guard httpRes.statusCode == 206 else { throw NSError(domain:"h",code:3) }
 guard (httpRes.allHeaderFields["Content-Range"] as? String) == "bytes 4-9/16" else { throw NSError(domain:"h",code:4) }
 guard b == Data("456789".utf8) else { throw NSError(domain:"h",code:5) }
 print("origin proxy host harness: PASS"); p.stop()
} }
'''

with tempfile.TemporaryDirectory() as d:
    root = pathlib.Path(__file__).resolve().parents[1]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Handler.port = server.server_port
    h = pathlib.Path(d) / "Harness.swift"; h.write_text(HARNESS.replace("PORT", str(server.server_port)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    out = pathlib.Path(d) / "harness"
    cmd = ["xcrun", "swiftc", "-warnings-as-errors", "-framework", "Network", "-o", str(out), str(root / "QuarkTheater/Playback/VLC/VLCOriginHTTPProxy.swift"), str(h)]
    subprocess.run(cmd, check=True)
    subprocess.run([str(out)], check=True)
    server.shutdown()
