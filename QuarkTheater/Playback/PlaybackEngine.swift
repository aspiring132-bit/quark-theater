import Foundation
import UIKit

/// Neutral playback surface used by PlaybackCoordinator and PlayerScreen.
/// Implementations must deliver events on the main actor and tag every event
/// with the generation that created it.
@MainActor
protocol PlaybackEngine: AnyObject {
    var eventHandler: ((PlaybackEngineEvent) -> Void)? { get set }
    var snapshot: PlaybackSnapshot { get }
    var audioTracks: [PlaybackTrack] { get }
    var subtitleTracks: [PlaybackTrack] { get }

    func attachSurface(_ surface: UIView?)
    func load(_ resource: PlaybackResource, generation: Int)
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
    func selectAudioTrack(id: Int?)
    func selectSubtitleTrack(id: Int?)
}
