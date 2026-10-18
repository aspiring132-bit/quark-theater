import Foundation
import AVFoundation

struct CookieJSON: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
}

let sessionPath = "/Users/wangbin/.quark_theater_session.json"
guard let sessionData = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
      let cookies = try? JSONDecoder().decode([CookieJSON].self, from: sessionData) else {
    print("[✗] Failed to load cookies from \(sessionPath)")
    exit(1)
}

let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
let fileID = "a59b0301a875482db97d24fbb8d873e1"
let ts = Int64(Date().timeIntervalSince1970 * 1000)

print("============================================================")
print("🎬 Swift AVFoundation Background Playback Verification")
print("============================================================")
print("[*] Requesting Quark streaming URL for FID \(fileID)...")

let playURL = URL(string: "https://drive.quark.cn/1/clouddrive/file/v2/play?pr=ucpro&fr=pc&sys=win32&ve=2.5.56&_t=\(ts)")!
var request = URLRequest(url: playURL)
request.httpMethod = "POST"
request.addValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 quark-cloud-drive/2.5.20", forHTTPHeaderField: "User-Agent")
request.addValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
request.addValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
request.addValue(cookieHeader, forHTTPHeaderField: "Cookie")
request.addValue("application/json", forHTTPHeaderField: "Content-Type")

let body: [String: Any] = [
    "fid": fileID,
    "resolutions": "original,4k,2k,super,high,low",
    "supports": "fmp4,hls,mp4"
]
request.httpBody = try! JSONSerialization.data(withJSONObject: body)

let semaphore = DispatchSemaphore(value: 0)
var resolvedStreamURL: URL?

URLSession.shared.dataTask(with: request) { data, response, error in
    defer { semaphore.signal() }
    guard let data = data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let dataObj = json["data"] as? [String: Any],
          let videoList = dataObj["video_list"] as? [[String: Any]],
          let first = videoList.first,
          let videoInfo = first["video_info"] as? [String: Any],
          let urlString = videoInfo["url"] as? String,
          let streamURL = URL(string: urlString) else {
        print("[✗] Failed to parse stream URL from response")
        return
    }
    resolvedStreamURL = streamURL
}.resume()

_ = semaphore.wait(timeout: .now() + 10)

guard let streamURL = resolvedStreamURL else {
    print("[✗] Error: Could not resolve stream URL from Quark")
    exit(1)
}

print("[✓] Resolved CDN Stream URL: \(streamURL.absoluteString.prefix(70))...")

// MARK: - AVPlayer & AVURLAsset Verification
let headers: [String: String] = [
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 quark-cloud-drive/2.5.20",
    "Origin": "https://pan.quark.cn",
    "Referer": "https://pan.quark.cn/",
    "Cookie": cookieHeader
]

let asset = AVURLAsset(url: streamURL, options: [
    "AVURLAssetHTTPHeaderFieldsKey": headers
])

let playerItem = AVPlayerItem(asset: asset)
playerItem.preferredForwardBufferDuration = 3.0 // Correct 3.0s buffer threshold

let player = AVPlayer(playerItem: playerItem)

print("[*] Loading media asset asynchronously with AVFoundation...")

var isReady = false
var hasPlayed = false
let group = DispatchGroup()
group.enter()

let observer = playerItem.observe(\.status, options: [.initial, .new]) { item, _ in
    switch item.status {
    case .readyToPlay:
        print("[✓] AVPlayerItem status: .readyToPlay! (Duration: \(CMTimeGetSeconds(item.duration))s)")
        isReady = true
        player.play()
    case .failed:
        print("[✗] AVPlayerItem failed: \(String(describing: item.error))")
        group.leave()
    default:
        break
    }
}

// Check playback progress every 500ms
let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
    if isReady {
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        let loadedRanges = playerItem.loadedTimeRanges.map { value -> (Double, Double) in
            let range = value.timeRangeValue
            return (CMTimeGetSeconds(range.start), CMTimeGetSeconds(range.duration))
        }
        print("    [Playback Tick] CurrentTime: \(String(format: "%.2f", currentSeconds))s, Buffered Ranges: \(loadedRanges)")
        if currentSeconds > 1.0 {
            print("[✓] Video stream is playing smoothly! (CurrentTime > 1.0s)")
            hasPlayed = true
            t.invalidate()
            group.leave()
        }
    }
}

RunLoop.main.run(until: Date().addingTimeInterval(15))

if hasPlayed {
    print("============================================================")
    print("🎉 BACKGROUND STREAM PLAYBACK VERIFIED SUCCESSFULLY!")
    print("============================================================")
    exit(0)
} else {
    print("[✗] Playback test timed out or did not advance")
    exit(1)
}
