import SwiftUI

@MainActor
struct DiagnosticsSettingsScreen: View {
    @ObservedObject var model: SessionViewModel
    var onBack: () -> Void = {}

    @State private var diagnosticCategory: DiagnosticCategory?
    @State private var isExportingLogs = false
    @State private var exportAlertMessage: String?
    @State private var showExportAlert = false
    @State private var diagnosticsMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    Button(action: onBack) {
                        Label("返回设置", systemImage: "arrow.left")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("日志与诊断")
                        .font(.system(size: 38, weight: .bold))
                    Text("最近运行事件（自动脱敏，不记录 Cookie、Token 与完整流签名 URL）。支持本地打包与外发维护邮箱。")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Action Bar
                HStack(spacing: 20) {
                    Button {
                        exportDiagnostics()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.badge")
                            Text(isExportingLogs ? "正在打包并发送…" : "导出日志并发送至维护邮箱")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.glassWhite)
                    .disabled(isExportingLogs)

                    Button("清空运行日志") {
                        diagnosticsMessage = nil
                        Task {
                            switch await model.diagnostics.clear().value {
                            case .success:
                                diagnosticsMessage = "日志已清空。"
                            case .failure(let failure):
                                diagnosticsMessage = "清空日志失败（\(failure.operation.rawValue)，错误码 \(failure.code)）"
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Picker("分类筛选", selection: $diagnosticCategory) {
                        Text("全部类别").tag(DiagnosticCategory?.none)
                        ForEach(DiagnosticCategory.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(Optional(category))
                        }
                    }
                    .pickerStyle(.menu)
                }
                .focusSection()

                // Records List
                VStack(alignment: .leading, spacing: 10) {
                    if visibleDiagnosticRecords.isEmpty {
                        Text("暂无符合当前筛选条件的诊断记录。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(visibleDiagnosticRecords) { record in
                            HStack(alignment: .top, spacing: 16) {
                                Text(record.date, style: .time)
                                    .monospacedDigit()
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("[\(record.category.rawValue)] \(record.event.rawValue)")
                                        .font(.caption.bold())
                                    Text(diagnosticSummary(record))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(24)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                .focusSection()

                if let failure = model.diagnostics.storageFailure {
                    Text("日志存储失败（\(failure.operation.rawValue)，错误码 \(failure.code)）")
                        .foregroundStyle(.orange)
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage).foregroundStyle(BrandPalette.glassWhite)
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(60)
        }
        .onExitCommand(perform: onBack)
        .alert("系统诊断报告", isPresented: $showExportAlert, actions: {
            Button("好的", role: .cancel) {}
        }, message: {
            Text(exportAlertMessage ?? "")
        })
    }

    private var visibleDiagnosticRecords: [DiagnosticRecord] {
        DiagnosticRecordProjection.visible(model.diagnostics.records, category: diagnosticCategory)
    }

    private func diagnosticSummary(_ record: DiagnosticRecord) -> String {
        record.metadata.keys.sorted().compactMap { key in
            guard let value = record.metadata[key] else { return nil }
            return "\(key)=\(String(describing: value))"
        }.joined(separator: " · ")
    }

    private func exportDiagnostics() {
        isExportingLogs = true
        Task {
            let result = await DiagnosticMailDispatcher.dispatchPackage(
                diagnostics: model.diagnostics,
                accountName: model.account?.displayName
            )
            isExportingLogs = false
            switch result {
            case .success(let outcome):
                let archiveName = outcome.archiveURL.lastPathComponent
                diagnosticsMessage = "已打包存档：\(archiveName)"
                switch outcome.remoteStatus {
                case .sent:
                    exportAlertMessage = "系统日志与设备信息已成功打包，并已发送至开发者维护邮箱：\n\(DiagnosticMailDispatcher.recipientEmail)"
                    model.diagnostics.record("诊断日志已打包并成功外发。")
                case .notConfigured:
                    exportAlertMessage = "日志已在设备本地打包存档（\(archiveName)）。\n当前版本未配置邮件中继服务器，无法自动外发至 \(DiagnosticMailDispatcher.recipientEmail)。"
                    model.diagnostics.record("诊断日志已本地打包；未配置邮件中继，未外发。")
                case .failed(let reason):
                    exportAlertMessage = "日志已在设备本地打包存档（\(archiveName)），但发送至维护邮箱失败：\(reason)"
                    model.diagnostics.record("诊断日志外发失败：\(reason)")
                }
                showExportAlert = true
            case .failure(let error):
                diagnosticsMessage = "打包失败：\(error.localizedDescription)"
                exportAlertMessage = "打包日志失败：\(error.localizedDescription)"
                model.diagnostics.record("诊断日志打包失败。")
                showExportAlert = true
            }
        }
    }
}
