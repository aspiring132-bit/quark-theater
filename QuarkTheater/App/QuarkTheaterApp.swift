import AVFoundation
import SwiftUI

/// 本地数据库启动报告。2026-10-18 真机卡死根因修复：初始化失败不再被
/// `try?` 静默吞掉，失败原因进入诊断日志并驱动 RootView 的恢复面板。
struct StorageBootReport {
    var historyFailure: String?
    var catalogFailure: String?
    /// 主库初始化失败后，是否已回退到临时降级库（可看首页，但数据不持久化）
    var historyDegraded = false
    var catalogDegraded = false

    var hasFailure: Bool { historyFailure != nil || catalogFailure != nil }
    var isDegraded: Bool { historyDegraded || catalogDegraded }

    var summary: String {
        [historyFailure.map { "观看记录库：\($0)" },
         catalogFailure.map { "影视媒体库：\($0)" }]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

@main
@MainActor
struct QuarkTheaterApp: App {
    @StateObject private var model = SessionViewModel()
    @State private var history: HistoryRepository?
    @State private var mediaCatalog: MediaCatalogRepository?
    @State private var storageBoot = StorageBootReport()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        try? session.setActive(true)

        let boot = Self.openRepositories()
        _history = State(initialValue: boot.history)
        _mediaCatalog = State(initialValue: boot.mediaCatalog)
        _storageBoot = State(initialValue: boot.report)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                model: model,
                history: history,
                mediaCatalog: mediaCatalog,
                storageBoot: storageBoot,
                onRetryStorage: reloadRepositories,
                onResetStorage: resetStorageAndReload
            )
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

    // MARK: - 本地仓储启动 / 恢复

    private struct RepositoryBoot {
        let history: HistoryRepository?
        let mediaCatalog: MediaCatalogRepository?
        let report: StorageBootReport
    }

    /// 打开本地两个 SQLite 仓储。任何失败都显式记录进 StorageBootReport；
    /// 主库失败时自动回退到临时目录的降级库，保证首页不被锁死。
    private static func openRepositories(deletingExisting: Bool = false) -> RepositoryBoot {
        if deletingExisting { deleteStorageFiles() }
        var report = StorageBootReport()

        var history: HistoryRepository? = nil
        if let url = StoragePaths.watchHistoryDatabaseURL() {
            do {
                history = try HistoryRepository(url: url)
            } catch {
                report.historyFailure = error.localizedDescription
            }
        } else {
            report.historyFailure = "无法解析本地存储路径。"
        }
        if history == nil, let scratch = scratchURL("watch-history-scratch.sqlite") {
            history = try? HistoryRepository(url: scratch)
            report.historyDegraded = history != nil
        }

        var catalog: MediaCatalogRepository? = nil
        if let url = StoragePaths.mediaCatalogDatabaseURL() {
            do {
                catalog = try MediaCatalogRepository(url: url)
            } catch {
                report.catalogFailure = error.localizedDescription
            }
        } else {
            report.catalogFailure = "无法解析本地存储路径。"
        }
        if catalog == nil, let scratch = scratchURL("media-catalog-scratch.sqlite") {
            catalog = try? MediaCatalogRepository(url: scratch)
            report.catalogDegraded = catalog != nil
        }

        return RepositoryBoot(history: history, mediaCatalog: catalog, report: report)
    }

    private static func scratchURL(_ name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuarkTheaterScratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private static func deleteStorageFiles() {
        guard let dir = StoragePaths.appSupportDirectory else { return }
        let fileManager = FileManager.default
        for name in ["watch-history.sqlite", "media-catalog.sqlite"] {
            let base = dir.appendingPathComponent(name)
            try? fileManager.removeItem(at: base)
            try? fileManager.removeItem(at: URL(fileURLWithPath: base.path + "-wal"))
            try? fileManager.removeItem(at: URL(fileURLWithPath: base.path + "-shm"))
        }
    }

    private func reloadRepositories() {
        let boot = Self.openRepositories()
        history = boot.history
        mediaCatalog = boot.mediaCatalog
        storageBoot = boot.report
        if boot.report.hasFailure {
            model.diagnostics.record("本地数据库重试初始化未完全成功。")
        } else {
            model.diagnostics.record("本地数据库初始化成功（手动重试）。")
        }
    }

    private func resetStorageAndReload() {
        model.diagnostics.record("用户选择清除本地缓存并重建数据库。")
        history = nil
        mediaCatalog = nil
        let boot = Self.openRepositories(deletingExisting: true)
        history = boot.history
        mediaCatalog = boot.mediaCatalog
        storageBoot = boot.report
        if boot.report.hasFailure {
            model.diagnostics.record("清除重建后本地数据库仍初始化失败。")
        } else {
            model.diagnostics.record("本地数据库已清除并重建成功。")
        }
    }
}
