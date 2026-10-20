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
    var episodeFileIDs: [String] = []
    var currentEpisodeFileID: String? = nil
    var subtitleTrackIDs: [String] = []
    var audioTrackIDs: [String] = []
}

enum PlayerInputReducer {
    static let orderedTabs = ["选集", "字幕", "音轨"]

    /// Projects native tvOS focus changes back into the drawer's selected-tab
    /// state without issuing another focus movement.
    static func selectedTabName(for target: PlayerFocusTarget?) -> String? {
        guard case .drawerTab(let name) = target,
              orderedTabs.contains(name) else { return nil }
        return name
    }

    static func reduce(state: PlayerInputState, direction: MoveCommandDirection, seekInterval: Int) -> PlayerRemoteAction {
        switch direction {
        case .down:
            if !state.isDrawerOpen {
                return .openDrawer
            } else if isTabLevel(state.focusedTarget) {
                return .focusTarget(defaultContentTarget(
                    tab: state.selectedDrawerTab,
                    canPlayNext: state.canPlayNext,
                    episodeFileIDs: state.episodeFileIDs,
                    subtitleTrackIDs: state.subtitleTrackIDs,
                    audioTrackIDs: state.audioTrackIDs,
                    currentEpisodeFileID: state.currentEpisodeFileID
                ))
            } else {
                return .none
            }

        case .up:
            if state.isDrawerOpen {
                if isContentLevel(state.focusedTarget) {
                    return .focusTarget(.drawerTab(state.selectedDrawerTab))
                } else {
                    // Up arrow does not close drawer; only back/menu key closes drawer
                    return .none
                }
            } else {
                return .none
            }

        case .left:
            if !state.isDrawerOpen {
                return .seek(direction: .backward, interval: PlayerSeekMath.normalizedInterval(seekInterval))
            }
            // The tvOS focus engine owns horizontal movement inside the drawer.
            // Keeping this reducer silent prevents one remote event from moving
            // the native focus and the custom focus state a second time.
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
        guard let target else { return false }
        switch target {
        case .drawerTab, .closeDrawer, .silentMarker, .drawerTrigger:
            return true
        default:
            return false
        }
    }

    static func isContentLevel(_ target: PlayerFocusTarget?) -> Bool {
        guard let target else { return false }
        switch target {
        case .episode, .nextEpisode, .subtitle, .audio:
            return true
        default:
            return false
        }
    }

    static func handleBack(state: PlayerInputState) -> PlayerRemoteAction {
        // The Menu/Back button dismisses the drawer as a whole. Content-to-tab
        // navigation is intentionally reserved for the Up direction so a Back
        // press can never bubble through and dismiss the player underneath.
        state.isDrawerOpen ? .closeDrawer : .none
    }

    static func navigateTab(current: PlayerFocusTarget?, direction: Int) -> PlayerRemoteAction {
        let currentTabName: String
        if case .drawerTab(let name) = current {
            currentTabName = name
        } else {
            currentTabName = orderedTabs[0]
        }
        guard let idx = orderedTabs.firstIndex(of: currentTabName) else {
            return .focusTarget(.drawerTab(orderedTabs[0]))
        }
        let newIdx = idx + direction
        if newIdx >= 0 && newIdx < orderedTabs.count {
            return .focusTarget(.drawerTab(orderedTabs[newIdx]))
        }
        return .none
    }

    static func navigateContent(state: PlayerInputState, step: Int) -> PlayerRemoteAction {
        switch state.selectedDrawerTab {
        case "选集", "选集列表":
            var items: [PlayerFocusTarget] = []
            if state.canPlayNext {
                items.append(.nextEpisode)
            }
            items.append(contentsOf: state.episodeFileIDs.map { .episode($0) })
            guard !items.isEmpty else { return .none }

            guard let current = state.focusedTarget, let idx = items.firstIndex(of: current) else {
                return .focusTarget(items[0])
            }
            let newIdx = idx + step
            if newIdx >= 0 && newIdx < items.count {
                return .focusTarget(items[newIdx])
            }
            return .none

        case "字幕":
            let items: [PlayerFocusTarget] = (state.subtitleTrackIDs.isEmpty ? ["off"] : state.subtitleTrackIDs).map { .subtitle($0) }
            guard !items.isEmpty else { return .none }
            guard let current = state.focusedTarget, let idx = items.firstIndex(of: current) else {
                return .focusTarget(items[0])
            }
            let newIdx = idx + step
            if newIdx >= 0 && newIdx < items.count {
                return .focusTarget(items[newIdx])
            }
            return .none

        case "音轨":
            let items: [PlayerFocusTarget] = (state.audioTrackIDs.isEmpty ? ["0"] : state.audioTrackIDs).map { .audio($0) }
            guard !items.isEmpty else { return .none }
            guard let current = state.focusedTarget, let idx = items.firstIndex(of: current) else {
                return .focusTarget(items[0])
            }
            let newIdx = idx + step
            if newIdx >= 0 && newIdx < items.count {
                return .focusTarget(items[newIdx])
            }
            return .none

        default:
            return .none
        }
    }

    static func defaultContentTarget(
        tab: String,
        canPlayNext: Bool,
        episodeFileIDs: [String] = [],
        subtitleTrackIDs: [String] = [],
        audioTrackIDs: [String] = [],
        currentEpisodeFileID: String? = nil
    ) -> PlayerFocusTarget {
        switch tab {
        case "选集", "选集列表":
            if let currentEpisodeFileID, episodeFileIDs.contains(currentEpisodeFileID) {
                return .episode(currentEpisodeFileID)
            }
            if canPlayNext { return .nextEpisode }
            if let firstID = episodeFileIDs.first { return .episode(firstID) }
            return .episode("first")
        case "字幕":
            if let first = subtitleTrackIDs.first { return .subtitle(first) }
            return .subtitle("off")
        case "音轨":
            if let first = audioTrackIDs.first { return .audio(first) }
            return .audio("0")
        default:
            return .drawerTab(tab)
        }
    }
}
