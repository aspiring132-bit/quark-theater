import SwiftUI

@main
@MainActor
struct QuarkTheaterApp: App {
    @StateObject private var model = SessionViewModel()
    private let history: HistoryRepository? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("QuarkTheater", isDirectory: true).appendingPathComponent("watch-history.sqlite")
        return try? HistoryRepository(url: url)
    }()
    private let mediaCatalog: MediaCatalogRepository? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("QuarkTheater", isDirectory: true).appendingPathComponent("media-catalog.sqlite")
        return try? MediaCatalogRepository(url: url)
    }()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model, history: history, mediaCatalog: mediaCatalog)
                .preferredColorScheme(.dark)
                .task {
                    guard !ProcessInfo.processInfo.arguments.contains("--testing") else { return }
                    await model.restore()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .background { model.cancelLogin() }
                }
        }
    }
}
