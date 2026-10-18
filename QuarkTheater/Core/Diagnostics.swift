import Foundation
import Combine

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

@MainActor
final class Diagnostics: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []
    @Published private(set) var records: [DiagnosticRecord]
    @Published private(set) var storageFailure: DiagnosticsStoreFailure?
    let store: DiagnosticsStore
    private var operationTail: Task<Void, Never> = Task {}
    private var lastFocusTarget: DiagnosticFocusTarget?
    private var lastFocusDate: Date?
    private let focusTransitionMinimumInterval: TimeInterval = 0.2

    init(store: DiagnosticsStore = DiagnosticsStore()) {
        self.store = store
        self.records = store.initialRecords
        self.storageFailure = nil
        self.lastFocusTarget = nil
        self.lastFocusDate = nil
        operationTail = Task { @MainActor [weak self, store] in
            let loaded = await store.recent()
            guard let self else { return }
            self.records = loaded
        }
    }

    /// Call only with application-owned messages. Never pass response bodies, URLs or credentials.
    func record(_ message: String) {
        entries.insert(DiagnosticEntry(message: message), at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
        record(category: .navigation, level: .debug, event: .legacyMessage)
    }

    func makeCorrelationID() -> DiagnosticCorrelationID {
        store.makeCorrelationID()
    }

    func record(
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        event: DiagnosticEvent,
        correlationID: DiagnosticCorrelationID? = nil,
        metadata: [DiagnosticMetadata] = []
    ) {
        enqueue { [weak self, store] in
            let result = await store.append(category: category, level: level, event: event, correlationID: correlationID, metadata: metadata)
            guard let self else { return }
            switch result {
            case .success(let record):
                self.storageFailure = nil
                self.records.insert(record, at: 0)
                if self.records.count > DiagnosticsStore.maxVisibleRecords {
                    self.records.removeLast(self.records.count - DiagnosticsStore.maxVisibleRecords)
                }
            case .failure(let failure):
                self.storageFailure = failure
            }
        }
    }

    /// Records only coarse, allowlisted focus regions. Repeated transitions are
    /// collapsed so remote focus churn cannot flood the persistent log.
    func recordFocusTransition(_ target: DiagnosticFocusTarget, now: Date = Date()) {
        if target == lastFocusTarget {
            return
        }
        if let lastFocusDate,
           now.timeIntervalSince(lastFocusDate) < focusTransitionMinimumInterval {
            return
        }
        lastFocusTarget = target
        lastFocusDate = now
        record(category: .navigation, level: .debug, event: .focusChanged,
               metadata: [.focusTarget(target)])
    }

    func recordError(_ error: Error, context: String) {
        if let error = error as? QuarkError {
            switch error {
            case .httpStatus(let status): record("\(context)：HTTP \(status)")
            case .server(let code, _): record("\(context)：业务错误 \(code)")
            case .forbidden: record("\(context)：403，停止自动重试")
            case .rateLimited: record("\(context)：429，停止自动重试")
            case .authenticationRequired: record("\(context)：需要重新登录")
            default: record("\(context)：接口/安全存储/播放条件未满足")
            }
        } else {
            let code = (error as NSError).code
            record("\(context)：系统错误码 \(code)")
        }
    }

    @discardableResult
    func clear() -> Task<Result<Void, DiagnosticsStoreFailure>, Never> {
        enqueueResult { [weak self, store] in
            let result = await store.clear()
            if let self {
                switch result {
                case .success:
                    self.storageFailure = nil
                    self.entries.removeAll()
                    self.records.removeAll()
                case .failure(let failure):
                    self.storageFailure = failure
                }
            }
            return result
        }
    }

    func export() async -> Result<URL, DiagnosticsStoreFailure> {
        await enqueueResult { [weak self, store] in
            let result = await store.export()
            if let self {
                switch result {
                case .success:
                    self.storageFailure = nil
                case .failure(let failure):
                    self.storageFailure = failure
                }
            }
            return result
        }.value
    }

    func waitForPendingOperations() async {
        await operationTail.value
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = operationTail
        operationTail = Task { @MainActor in
            await previous.value
            await operation()
        }
    }

    private func enqueueResult<T>(_ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = operationTail
        let task = Task { @MainActor in
            await previous.value
            return await operation()
        }
        operationTail = Task { @MainActor in
            _ = await task.value
        }
        return task
    }
}

func userFacingError(_ error: Error) -> String {
    if let error = error as? QuarkError { return error.errorDescription ?? "操作失败。" }
    if let error = error as? URLError {
        switch error.code {
        case .timedOut: return "网络请求超时，请检查网络后重试。"
        case .notConnectedToInternet: return "当前未连接互联网。"
        case .cancelled: return "操作已取消。"
        default: return "网络错误（\(error.code.rawValue)），请检查网络。"
        }
    }
    return "操作失败（错误码 \((error as NSError).code)）。请查看诊断记录。"
}
