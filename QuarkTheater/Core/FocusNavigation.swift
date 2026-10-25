import Foundation

enum RootTab: String, Hashable, CaseIterable {
    case media, sources, settings

    var title: String {
        switch self {
        case .media: return "影院"
        case .sources: return "网盘管理"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .media: return "film.stack"
        case .sources: return "externaldrive.connected.to.line.below"
        case .settings: return "gearshape"
        }
    }
}

enum RootFocusReducer {
    static func selectedTabAfterBack(_ tab: RootTab) -> RootTab {
        .media
    }

    static func shouldConsumeBack(_ tab: RootTab) -> Bool {
        tab != .media
    }

    static func dockTarget(for tab: RootTab) -> RootTab { tab }
}

enum SettingsCategory: String, Hashable, CaseIterable, Identifiable {
    case sources = "sources"
    case playback = "playback"
    case scraper = "scraper"
    case dataCache = "dataCache"
    case diagnostics = "diagnostics"
    case about = "about"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return "媒体来源"
        case .playback: return "播放偏好"
        case .scraper: return "刮削与匹配"
        case .dataCache: return "数据与缓存"
        case .diagnostics: return "日志与诊断"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .sources: return "已连接云盘与 NAS 摘要，跳转至网盘管理"
        case .playback: return "自动连播、快进/快退步长与播放偏好"
        case .scraper: return "TMDB 元数据刮削源、语言与已学习别名"
        case .dataCache: return "观看记录、影视匹配缓存与账号退出"
        case .diagnostics: return "运行事件过滤、清空日志与维护邮箱导出"
        case .about: return "版本信息、原生体验与开源组件许可"
        }
    }

    var icon: String {
        switch self {
        case .sources: return "externaldrive.connected.to.line.below"
        case .playback: return "play.circle"
        case .scraper: return "sparkles.tv"
        case .dataCache: return "cylinder.split.1x2"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

enum SettingsFocusReducer {
    static func shouldConsumeBack(selectedCategory: SettingsCategory?) -> Bool {
        selectedCategory != nil
    }

    static func categoryAfterBack(selectedCategory: SettingsCategory?) -> SettingsCategory? {
        nil
    }

    static func restoredFocusTarget(afterExiting category: SettingsCategory) -> SettingsCategory {
        category
    }
}

enum FolderBindingBackdropStyle {
    static let blurRadius: CGFloat = 24
    static let dimmingOpacity: Double = 0.72

    static func blur(isPresented: Bool) -> CGFloat {
        isPresented ? blurRadius : 0
    }

    static func dimming(isPresented: Bool) -> Double {
        isPresented ? dimmingOpacity : 0
    }
}

enum DrawerButtonFocusStyle {
    static let focusedScale: CGFloat = 1.05
    static let defaultScale: CGFloat = 1.0

    static func scale(isFocused: Bool) -> CGFloat {
        isFocused ? focusedScale : defaultScale
    }

    /// tvOS custom-highlighted cards must use .plain button style rather than
    /// .borderless to avoid system icon-only enlargement or split focus rings.
    static var prefersPlainButtonStyle: Bool {
        true
    }
}


enum FocusDiagnostics {
    static let historyTarget: DiagnosticFocusTarget = .historyRow
    static let tmdbTarget: DiagnosticFocusTarget = .tmdbResult

    static func target(for target: FileBrowserFocusTarget) -> DiagnosticFocusTarget {
        switch target {
        case .search: return .fileBrowserSearch
        case .header: return .fileBrowserSearch
        case .file: return .fileBrowserRow
        }
    }

    static func target(for target: FolderFocusTarget) -> DiagnosticFocusTarget {
        switch target {
        case .cancel, .breadcrumb: return .folderBreadcrumb
        case .folderSelect, .folderEnter: return .folderRow
        }
    }

    static func target(for target: PlayerFocusTarget) -> DiagnosticFocusTarget {
        switch target {
        case .drawerTrigger, .drawerTab, .closeDrawer: return .playerDrawer
        case .episode, .nextEpisode: return .playerEpisode
        case .subtitle, .audio, .silentMarker, .skipIntro, .skipOutro: return .playerOption
        }
    }
}

enum LibraryFocusTarget: Hashable {
    case heroDetails
    case heroPlay
    case heroRematch
    case episode(String)
    case filter(String)
}

enum PlayerFocusTarget: Hashable {
    case drawerTrigger
    case drawerTab(String)
    case closeDrawer
    case silentMarker
    case skipIntro
    case skipOutro
    case nextEpisode
    case episode(String)
    case subtitle(String)
    case audio(String)
}

enum PlayerSeekDirection: Equatable {
    case backward
    case forward
}

enum PlayerSeekMath {
    static func nextTarget(current: Double, pending: Double?, inFlight: Double? = nil,
                           direction: PlayerSeekDirection, interval: Int, duration: Double?) -> Double? {
        target(current: pending ?? inFlight ?? current, direction: direction, interval: interval, duration: duration)
    }

    static func normalizedInterval(_ raw: Int) -> Int {
        raw == 15 ? 15 : 10
    }

    static func target(current: Double, direction: PlayerSeekDirection, interval: Int, duration: Double?) -> Double? {
        guard current.isFinite, current >= 0 else { return nil }
        guard interval > 0 else { return current }
        let seconds = Double(interval)
        let candidate = direction == .forward ? current + seconds : current - seconds
        guard candidate.isFinite else { return nil }
        guard let duration, duration.isFinite, duration > 0 else { return max(0, candidate) }
        return min(max(0, candidate), duration)
    }
}

enum DiagnosticRecordProjection {
    static func visible(_ records: [DiagnosticRecord], category: DiagnosticCategory?, limit: Int = 500) -> [DiagnosticRecord] {
        Array(records
            .filter { category == nil || $0.category == category }
            .sorted { $0.date > $1.date }
            .prefix(max(0, limit)))
    }
}

enum PlayerSeekPreference {
    static let key = "QuarkTheater.playerSeekIntervalSeconds"
    static let defaultInterval = 10

    static var current: Int {
        let defaults = UserDefaults.standard
        guard let raw = defaults.object(forKey: key) else { return defaultInterval }
        guard let number = raw as? NSNumber else {
            defaults.set(defaultInterval, forKey: key)
            return defaultInterval
        }
        let value = number.intValue
        guard value == 10 || value == 15 else {
            defaults.set(defaultInterval, forKey: key)
            return defaultInterval
        }
        return value
    }
}

enum PlayerSeekHUDPolicy {
    static let quietPeriod: TimeInterval = 3

    static func shouldHide(now: Date, lastInteraction: Date?) -> Bool {
        guard let lastInteraction else { return false }
        return now.timeIntervalSince(lastInteraction) >= quietPeriod
    }
}

enum PlayerSeekRepeatPolicy {
    static func interval(configured: Int, repeatCount: Int) -> Int {
        let base = PlayerSeekMath.normalizedInterval(configured)
        return base * min(max(repeatCount + 1, 1), 4)
    }
}
