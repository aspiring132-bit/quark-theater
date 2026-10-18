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
        case .subtitle, .audio, .silentMarker: return .playerOption
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
        let seconds = Double(normalizedInterval(interval))
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
