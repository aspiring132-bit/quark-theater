import Foundation
import SwiftUI

enum PlayerRemoteAction: Equatable {
    case openDrawer
    case closeDrawer
    case focusTarget(PlayerFocusTarget)
    case seek(direction: PlayerSeekDirection, interval: Int)
    case togglePlayPause
    case none
}

struct PlayerInputState: Equatable {
    var isDrawerOpen: Bool
    var selectedDrawerTab: String
    var focusedTarget: PlayerFocusTarget?
    var canPlayNext: Bool
    var currentPlaybackTime: Double
    var duration: Double
}

enum PlayerInputReducer {
    static func reduce(state: PlayerInputState, direction: MoveCommandDirection, seekInterval: Int) -> PlayerRemoteAction {
        switch direction {
        case .down:
            if !state.isDrawerOpen {
                return .openDrawer
            } else if isTabLevel(state.focusedTarget) {
                return .focusTarget(defaultContentTarget(tab: state.selectedDrawerTab, canPlayNext: state.canPlayNext))
            } else {
                return .none
            }
        case .up:
            if state.isDrawerOpen {
                if isTabLevel(state.focusedTarget) {
                    return .closeDrawer
                } else {
                    return .focusTarget(.drawerTab(state.selectedDrawerTab))
                }
            } else {
                return .none
            }
        case .left:
            if !state.isDrawerOpen {
                return .seek(direction: .backward, interval: PlayerSeekMath.normalizedInterval(seekInterval))
            }
            return .none
        case .right:
            if !state.isDrawerOpen {
                return .seek(direction: .forward, interval: PlayerSeekMath.normalizedInterval(seekInterval))
            }
            return .none
        default:
            return .none
        }
    }

    static func isTabLevel(_ target: PlayerFocusTarget?) -> Bool {
        guard let target else { return true }
        switch target {
        case .drawerTab, .closeDrawer, .silentMarker, .drawerTrigger:
            return true
        default:
            return false
        }
    }

    static func defaultContentTarget(tab: String, canPlayNext: Bool) -> PlayerFocusTarget {
        switch tab {
        case "选集列表":
            return canPlayNext ? .nextEpisode : .episode("first")
        case "字幕":
            return .subtitle("off")
        case "音轨":
            return .audio("0")
        default:
            return .drawerTab(tab)
        }
    }
}
