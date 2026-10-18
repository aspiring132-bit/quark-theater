import AVFoundation
import Foundation
import UIKit

@MainActor
final class DiagnosticMailDispatcher {
    static let recipientEmail = "aspiring.ad@outlook.com"

    struct DeviceReport: Codable {
        let deviceName: String
        let model: String
        let systemName: String
        let systemVersion: String
        let appVersion: String
        let buildNumber: String
        let physicalMemoryGB: Double
        let audioRoute: String
        let accountName: String
        let timestamp: Date
    }

    struct FullDiagnosticPayload: Codable {
        let recipient: String
        let device: DeviceReport
        let logCount: Int
        let logs: [DiagnosticRecord]
        let generatedAt: Date
    }

    static func buildPayload(diagnostics: Diagnostics, accountName: String?) -> FullDiagnosticPayload {
        let audioRoute = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let memBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let memGB = (memBytes / (1024 * 1024 * 1024) * 10).rounded() / 10

        let device = DeviceReport(
            deviceName: UIDevice.current.name,
            model: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            physicalMemoryGB: memGB,
            audioRoute: audioRoute.isEmpty ? "未连接" : audioRoute,
            accountName: accountName ?? "未登录",
            timestamp: Date()
        )

        return FullDiagnosticPayload(
            recipient: recipientEmail,
            device: device,
            logCount: diagnostics.records.count,
            logs: diagnostics.records,
            generatedAt: Date()
        )
    }

    /// Dispatches the diagnostic package and device information to aspiring.ad@outlook.com.
    /// Also archives a local snapshot in the application diagnostics directory.
    static func dispatchPackage(diagnostics: Diagnostics, accountName: String?) async -> Result<URL, Error> {
        let payload = buildPayload(diagnostics: diagnostics, accountName: accountName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(payload)

            let folder = StoragePaths.appSupportDirectory?.appendingPathComponent("Diagnostics", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            let filename = "QuarkTheater_Diagnostics_\(df.string(from: Date())).json"
            let fileURL = folder.appendingPathComponent(filename)
            try data.write(to: fileURL, options: .atomic)

            // Asynchronous dispatch to the mail relay service
            if let webhookURL = URL(string: "https://api.quark-theater.org/api/v1/diagnostics/dispatch") {
                var request = URLRequest(url: webhookURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = data
                request.timeoutInterval = 8
                _ = try? await URLSession.shared.data(for: request)
            }

            return .success(fileURL)
        } catch {
            return .failure(error)
        }
    }
}
