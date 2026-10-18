import AVFoundation
import SwiftUI

@main
@MainActor
struct QuarkTheaterApp: App {
    @StateObject private var model = SessionViewModel()
    private let history: HistoryRepository? = {
        guard let url = StoragePaths.watchHistoryDatabaseURL() else { return nil }
        return try? HistoryRepository(url: url)
    }()
    private let mediaCatalog: MediaCatalogRepository? = {
        guard let url = StoragePaths.mediaCatalogDatabaseURL() else { return nil }
        return try? MediaCatalogRepository(url: url)
    }()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, history: history, mediaCatalog: mediaCatalog)
                .preferredColorScheme(.dark)
                .task {
                    guard !ProcessInfo.processInfo.arguments.contains("--testing") else { return }
                    await model.restore()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .background, model.isLoggingIn {
                        model.cancelLogin()
                    }
                }
        }
    }
}
