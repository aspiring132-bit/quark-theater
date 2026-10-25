#!/usr/bin/env python3
"""Reproducible host smoke test for the loopback VLC origin/HLS proxy."""
import http.server, pathlib, subprocess, tempfile, threading

class Handler(http.server.BaseHTTPRequestHandler):
    port = 0
    def do_GET(self):
        if self.path == "/master-single.m3u8":
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

        if self.path == "/master-with-variants.m3u8":
            p = str(Handler.port)
            lines = [
                '#EXTM3U',
                f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="http://127.0.0.1:{p}/audio.m3u8?token=abcdef"',
                f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="http://127.0.0.1:{p}/subs.m3u8?token=123456"',
                '#EXT-X-STREAM-INF:BANDWIDTH=1280000,AUDIO="audio",SUBTITLES="subs"',
                f'http://127.0.0.1:{p}/variant.m3u8',
            ]
            body = ('\n'.join(lines) + '\n').encode()
            self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return

        if self.path == "/variant.m3u8":
            p = str(Handler.port)
            lines = [
                '#EXTM3U',
                '#EXT-X-VERSION:3',
                '#EXT-X-TARGETDURATION:6',
                '#EXTINF:6.0,',
                f'http://127.0.0.1:{p}/variant-seg-0.ts',
                '#EXTINF:6.0,',
                f'http://127.0.0.1:{p}/variant-seg-1.ts',
                '#EXT-X-ENDLIST',
            ]
            body = ('\n'.join(lines) + '\n').encode()
            self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return

        if self.path.startswith("/audio.m3u8"):
            p = str(Handler.port)
            lines = [
                '#EXTM3U',
                '#EXT-X-VERSION:3',
                '#EXTINF:10.0,',
                f'http://127.0.0.1:{p}/audio-seg-0.aac',
                '#EXT-X-ENDLIST',
            ]
            body = ('\n'.join(lines) + '\n').encode()
            self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return

        if self.path.startswith("/subs.m3u8"):
            lines = [
                '#EXTM3U',
                '#EXT-X-VERSION:3',
                '#EXTINF:10.0,',
                'subs.vtt',
                '#EXT-X-ENDLIST',
            ]
            body = ('\n'.join(lines) + '\n').encode()
            self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return

        if self.path == "/variant-seg-0.ts":
            body = b"variantsegment0000"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "video/mp2t")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/audio-seg-0.aac":
            body = b"audiosegmentdata"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "audio/aac")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/vod.m3u8":
            p = str(Handler.port)
            lines = [
                '#EXTM3U',
                '#EXT-X-VERSION:3',
                '#EXT-X-TARGETDURATION:5',
                '#EXTINF:5.0,',
                f'http://127.0.0.1:{p}/segment-good.ts',
                '#EXTINF:5.0,',
                f'http://127.0.0.1:{p}/segment-truncated.ts',
                '#EXT-X-ENDLIST',
            ]
            body = ('\n'.join(lines) + '\n').encode()
            self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return

        if self.path == "/live.m3u8":
            lines = [
                '#EXTM3U',
                '#EXT-X-VERSION:3',
                '#EXTINF:5.0,',
                'segment-live.ts',
            ]
            body = ('\n'.join(lines) + '\n').encode()
            self.send_response(200); self.send_header("Content-Type", "application/vnd.apple.mpegurl"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return

        if self.path == "/segment-good.ts":
            body = b"goodsegmentbytes"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "video/mp2t")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/segment-truncated.ts":
            # Declare 100 bytes, send only 10 bytes then close abruptly
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.send_header("Content-Type", "video/mp2t")
            self.end_headers()
            self.wfile.write(b"0123456789")
            self.close_connection = True
            return

        if self.path == "/direct.mp4":
            body = b"mp4videoheaderanddata"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "video/mp4")
            self.end_headers()
            self.wfile.write(body)
            return

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
struct PlaybackTimeRange: Equatable, Hashable {
    let start: TimeInterval
    let end: TimeInterval
}
struct PlaybackResource { let fileID:String; let url:URL; let cookies:[HTTPCookie]; let requiredHTTPHeaders:[String:String]; let expiresAt:Date? }
enum PlaybackProbe { static func applicableCookies(_ c:[HTTPCookie], url:URL)->[HTTPCookie] { c } }
@main struct Main { static func main() async throws {
 let r=PlaybackResource(fileID:"test",url:URL(string:"http://127.0.0.1:PORT/master-single.m3u8")!,cookies:[],requiredHTTPHeaders:["Origin":"https://pan.quark.cn"],expiresAt:nil)
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
 p.stop()

 // Integration test: VOD manifest + segment download verifies buffer ranges appearance
 let vodRes = PlaybackResource(fileID:"vod-test", url:URL(string:"http://127.0.0.1:PORT/vod.m3u8")!, cookies:[], requiredHTTPHeaders:["Origin":"https://pan.quark.cn"], expiresAt:nil)
 let vodProxy = VLCOriginHTTPProxy(resource:vodRes, allowLoopbackForTesting:true)
 let vodURL = try await vodProxy.start()

 // 1. Fetch VOD manifest through proxy
 let (vodData, _) = try await URLSession.shared.data(from: vodURL)
 let vodManifestText = String(data: vodData, encoding: .utf8)!
 guard vodManifestText.contains("#EXT-X-ENDLIST") else { throw NSError(domain:"h", code:20) }

 // 2. Extract proxied segment URLs from manifest
 let vodLines = vodManifestText.components(separatedBy: .newlines).filter { $0.hasPrefix("http://127.0.0.1") }
 guard vodLines.count >= 2 else { throw NSError(domain:"h", code:21) }
 let goodSegURL = URL(string: vodLines[0])!
 let truncSegURL = URL(string: vodLines[1])!

 // Initially no ranges
 guard vodProxy.currentBufferedRanges().isEmpty else { throw NSError(domain:"h", code:22) }

 // 3. Download complete segment through proxy -> should appear in buffered ranges
 let (goodBytes, goodRes) = try await URLSession.shared.data(from: goodSegURL)
 guard (goodRes as! HTTPURLResponse).statusCode == 200, goodBytes == Data("goodsegmentbytes".utf8) else { throw NSError(domain:"h", code:23) }

 // Allow async queue to process completion
 try await Task.sleep(nanoseconds: 100_000_000)
 let bufferedAfterGood = vodProxy.currentBufferedRanges()
 guard bufferedAfterGood == [PlaybackTimeRange(start: 0.0, end: 5.0)] else {
     print("Unexpected buffered ranges after good segment: \(bufferedAfterGood)")
     throw NSError(domain:"h", code:24)
 }

 // 4. Download truncated segment through proxy -> should NOT appear in buffered ranges
 do {
     _ = try await URLSession.shared.data(from: truncSegURL)
 } catch {
     // Expected truncation/network error
 }
 try await Task.sleep(nanoseconds: 100_000_000)
 let bufferedAfterTrunc = vodProxy.currentBufferedRanges()
 guard bufferedAfterTrunc == [PlaybackTimeRange(start: 0.0, end: 5.0)] else {
     print("Unexpected buffered ranges after trunc segment: \(bufferedAfterTrunc)")
     throw NSError(domain:"h", code:25)
 }
 vodProxy.stop()

 // 5. Master playlist with video variants + separate audio/subtitles:
 // Request only variant media playlist and variant segment through proxy; prove only variant segment ranges are eligible.
 // Also request audio playlist and segment; verify audio segment does not contribute to buffered ranges.
 let masterRes = PlaybackResource(fileID:"master-test", url:URL(string:"http://127.0.0.1:PORT/master-with-variants.m3u8")!, cookies:[], requiredHTTPHeaders:["Origin":"https://pan.quark.cn"], expiresAt:nil)
 let masterProxy = VLCOriginHTTPProxy(resource:masterRes, allowLoopbackForTesting:true)
 let masterURL = try await masterProxy.start()

 // Fetch master playlist
 let (masterData, _) = try await URLSession.shared.data(from: masterURL)
 let masterText = String(data: masterData, encoding: .utf8)!

 // Find proxied variant playlist URL and proxied audio playlist URL from rewritten master
 var variantPlaylistURL: URL?
 var audioPlaylistURL: URL?
 for line in masterText.components(separatedBy: .newlines) {
     let trimmed = line.trimmingCharacters(in: .whitespaces)
     if trimmed.hasPrefix("http://127.0.0.1:") && !trimmed.contains("#") {
         if variantPlaylistURL == nil {
             variantPlaylistURL = URL(string: trimmed)
         }
     } else if trimmed.contains("#EXT-X-MEDIA:TYPE=AUDIO") {
         let parts = trimmed.components(separatedBy: "URI=\"")
         if parts.count > 1, let endIdx = parts[1].firstIndex(of: "\"") {
             audioPlaylistURL = URL(string: String(parts[1][..<endIdx]))
         }
     }
 }
 guard let variantURL = variantPlaylistURL, let audioURL = audioPlaylistURL else {
     throw NSError(domain:"h", code:26)
 }

 // Request audio playlist through proxy first
 let (audioData, _) = try await URLSession.shared.data(from: audioURL)
 let audioText = String(data: audioData, encoding: .utf8)!
 let audioSegLine = audioText.components(separatedBy: .newlines).first { $0.hasPrefix("http://127.0.0.1:") && !$0.contains("#") }
 guard let audioSegURL = audioSegLine.flatMap(URL.init) else {
     print("Failed to find audioSegURL in audioText:\n\(audioText)")
     throw NSError(domain:"h", code:27)
 }

 // Fetch audio segment through proxy -> must NOT appear in buffered ranges (alt audio is not video variant)
 let (audioSegBytes, audioSegRes) = try await URLSession.shared.data(from: audioSegURL)
 guard (audioSegRes as! HTTPURLResponse).statusCode == 200, !audioSegBytes.isEmpty else { throw NSError(domain:"h", code:28) }
 try await Task.sleep(nanoseconds: 100_000_000)
 guard masterProxy.currentBufferedRanges().isEmpty else {
     print("Audio segment unexpectedly contributed to buffered ranges: \(masterProxy.currentBufferedRanges())")
     throw NSError(domain:"h", code:29)
 }

 // Now request variant media playlist through proxy
 let (variantData, _) = try await URLSession.shared.data(from: variantURL)
 let variantText = String(data: variantData, encoding: .utf8)!
 guard variantText.contains("#EXT-X-ENDLIST") else { throw NSError(domain:"h", code:30) }
 let variantSegLine = variantText.components(separatedBy: .newlines).first { $0.hasPrefix("http://127.0.0.1:") && !$0.contains("#") }
 guard let variantSegURL = variantSegLine.flatMap(URL.init) else { throw NSError(domain:"h", code:31) }

 // Download variant segment through proxy -> MUST appear in buffered ranges
 let (varSegBytes, varSegRes) = try await URLSession.shared.data(from: variantSegURL)
 guard (varSegRes as! HTTPURLResponse).statusCode == 200, varSegBytes == Data("variantsegment0000".utf8) else { throw NSError(domain:"h", code:32) }
 try await Task.sleep(nanoseconds: 100_000_000)
 let masterRanges = masterProxy.currentBufferedRanges()
 guard masterRanges == [PlaybackTimeRange(start: 0.0, end: 6.0)] else {
     print("Expected variant segment buffered range [0, 6], got: \(masterRanges)")
     throw NSError(domain:"h", code:33)
 }
 masterProxy.stop()

 // 6. Direct MP4 suppresses ranges
 let mp4Res = PlaybackResource(fileID:"mp4-test", url:URL(string:"http://127.0.0.1:PORT/direct.mp4")!, cookies:[], requiredHTTPHeaders:["Origin":"https://pan.quark.cn"], expiresAt:nil)
 let mp4Proxy = VLCOriginHTTPProxy(resource:mp4Res, allowLoopbackForTesting:true)
 let mp4URL = try await mp4Proxy.start()
 let (mp4Bytes, _) = try await URLSession.shared.data(from: mp4URL)
 guard !mp4Bytes.isEmpty else { throw NSError(domain:"h", code:34) }
 try await Task.sleep(nanoseconds: 100_000_000)
 guard mp4Proxy.currentBufferedRanges().isEmpty else { throw NSError(domain:"h", code:35) }
 mp4Proxy.stop()

 // 7. Live playlist suppresses ranges
 let liveRes = PlaybackResource(fileID:"live-test", url:URL(string:"http://127.0.0.1:PORT/live.m3u8")!, cookies:[], requiredHTTPHeaders:["Origin":"https://pan.quark.cn"], expiresAt:nil)
 let liveProxy = VLCOriginHTTPProxy(resource:liveRes, allowLoopbackForTesting:true)
 let liveURL = try await liveProxy.start()
 let (liveBytes, _) = try await URLSession.shared.data(from: liveURL)
 guard !liveBytes.isEmpty else { throw NSError(domain:"h", code:40) }
 try await Task.sleep(nanoseconds: 100_000_000)
 guard liveProxy.currentBufferedRanges().isEmpty else { throw NSError(domain:"h", code:41) }
 liveProxy.stop()

 print("origin proxy host harness: PASS")
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
