import AVFoundation
import Foundation
import UIKit

@MainActor
final class DiagnosticMailDispatcher {
    static let recipientEmail = "aspiring.ad@outlook.com"

    /// Result of the remote e-mail relay attempt.
    enum RemoteDispatchStatus: Equatable {
        /// The relay endpoint accepted the package (HTTP 2xx).
        case sent
        /// No relay endpoint is configured in Info.plist (`DiagnosticsRelayURL`).
        case notConfigured
        /// The relay endpoint was unreachable or rejected the package.
        case failed(String)
    }

    struct DispatchOutcome {
        let archiveURL: URL
        let remoteStatus: RemoteDispatchStatus
    }

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

    /// Optional e-mail relay endpoint.
    ///
    /// tvOS has no system mail composer, so delivery requires an HTTPS relay
    /// that forwards the JSON payload to `recipientEmail`. Configure it by
    /// adding a `DiagnosticsRelayURL` string entry to the app's Info.plist
    /// (or an `INFOPLIST_KEY_DiagnosticsRelayURL` build setting). When the
    /// key is absent the package is still archived locally and the UI reports
    /// `.notConfigured` honestly instead of pretending the mail was sent.
    static var relayEndpointURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "DiagnosticsRelayURL") as? String,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
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

    /// Archives the diagnostic package locally, then attempts remote delivery
    /// to `recipientEmail` via the configured relay endpoint. The outcome
    /// always reflects what actually happened.
    static func dispatchPackage(diagnostics: Diagnostics, accountName: String?) async -> Result<DispatchOutcome, Error> {
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

            let remoteStatus = await dispatchRemotely(data: data)
            return .success(DispatchOutcome(archiveURL: fileURL, remoteStatus: remoteStatus))
        } catch {
            return .failure(error)
        }
    }

    private static func dispatchRemotely(data: Data) async -> RemoteDispatchStatus {
        guard let webhookURL = relayEndpointURL else { return .notConfigured }

        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return .sent
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return .failed("HTTP \(code)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
