import Foundation

enum PlaybackPreferences {
    static let seekIntervalKey = "QuarkTheater.playerSeekIntervalSeconds"
    static let autoPlayNextKey = "autoPlayNextEpisode"
    static let playbackEngineKey = "playbackEngine"

    static let defaultSeekInterval: Int = 10
    static let allowedSeekIntervals: [Int] = [10, 15]

    static var seekInterval: Int {
        get {
            let defaults = UserDefaults.standard
            guard let raw = defaults.object(forKey: seekIntervalKey) as? NSNumber else {
                return defaultSeekInterval
            }
            let val = raw.intValue
            return allowedSeekIntervals.contains(val) ? val : defaultSeekInterval
        }
        set {
            let validated = allowedSeekIntervals.contains(newValue) ? newValue : defaultSeekInterval
            UserDefaults.standard.set(validated, forKey: seekIntervalKey)
        }
    }

    static var autoPlayNext: Bool {
        get { UserDefaults.standard.bool(forKey: autoPlayNextKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoPlayNextKey) }
    }

    /// Primary unified engine: KSPlayer
    static var isKSPlayerPreferred: Bool {
        true
    }
}
