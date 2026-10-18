import Foundation
import OSLog

enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case navigation
    case cloud
    case scraping
    case playback
    case audio
}

enum DiagnosticLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

enum DiagnosticEvent: String, Codable, CaseIterable, Sendable {
    case focusChanged = "navigation.focus_changed"
    case requestCompleted = "cloud.request_completed"
    case requestFailed = "cloud.request_failed"
    case requestFallback = "cloud.request_fallback"
    case scrapingSearchCompleted = "scraping.search_completed"
    case scrapingSearchFailed = "scraping.search_failed"
    case started = "playback.started"
    case playbackState = "playback.state"
    case playbackError = "playback.error"
    case playbackSeek = "playback.seek"
    case audioSnapshot = "audio.snapshot"
    case audioError = "audio.error"
    case silentMarker = "audio.silent_marker"
    case legacyMessage = "diagnostics.legacy_message"
}

enum DiagnosticQuarkEndpoint: String, CaseIterable, Sendable {
    case loginToken = "login_token"
    case loginTicket = "login_ticket"
    case accountInfo = "account_info"
    case fileSort = "file_sort"
    case fileSearch = "file_search"
    case filePlay = "file_play"
    case fileDownload = "file_download"
    case unknown = "unknown"
}

/// Opaque token created by the diagnostics subsystem. Callers cannot turn account or file IDs into correlations.
struct DiagnosticCorrelationID: Hashable, Sendable {
    fileprivate let value: UUID
}

enum DiagnosticValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case string
        case int
        case double
        case bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

enum DiagnosticOutcome: String, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
    case partial
    case noMatch = "no_match"
}

enum DiagnosticReason: String, CaseIterable, Sendable {
    case none
    case authenticationRequired = "authentication_required"
    case forbidden
    case rateLimited = "rate_limited"
    case timedOut = "timed_out"
    case networkUnavailable = "network_unavailable"
    case cancelled
    case invalidResponse = "invalid_response"
    case unavailable
    case stalled
    case unknown
}

enum DiagnosticHost: String, CaseIterable, Sendable {
    case quarkAPI = "quark_api"
    case tmdbAPI = "tmdb_api"
    case local
}

enum DiagnosticMediaFormat: String, CaseIterable, Sendable {
    case hls
    case mp4
    case mov
    case mkv
    case webm
    case unknown
}

enum DiagnosticResolution: String, CaseIterable, Sendable {
    case standardDefinition = "sd"
    case highDefinition = "hd"
    case fullHD = "full_hd"
    case ultraHD = "ultra_hd"
    case unknown
}

enum DiagnosticPlayerState: String, CaseIterable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case waiting
    case ended
    case failed
}

enum DiagnosticWaitingReason: String, CaseIterable, Sendable {
    case none
    case evaluatingBufferingRate = "evaluating_buffering_rate"
    case toMinimizeStalls = "to_minimize_stalls"
    case noItemToPlay = "no_item_to_play"
    case unknown
}

enum DiagnosticAudioRoute: String, CaseIterable, Sendable {
    case hdmi
    case bluetooth
    case airPlay = "air_play"
    case builtIn = "built_in"
    case unknown
}

/// Closed set of app-level focus destinations. Never persist labels, IDs, or view-local tokens.
enum DiagnosticFocusTarget: String, CaseIterable, Sendable {
    case media
    case sources
    case settings
    case fileBrowserSearch = "file_browser_search"
    case fileBrowserRow = "file_browser_row"
    case folderBreadcrumb = "folder_breadcrumb"
    case folderRow = "folder_row"
    case historyToolbar = "history_toolbar"
    case historyRow = "history_row"
    case loginAction = "login_action"
    case mediaPoster = "media_poster"
    case mediaFilter = "media_filter"
    case mediaHeroAction = "media_hero_action"
    case playerDrawer = "player_drawer"
    case playerEpisode = "player_episode"
    case playerOption = "player_option"
    case tmdbSearch = "tmdb_search"
    case tmdbResult = "tmdb_result"
}

enum DiagnosticStatus: String, CaseIterable, Sendable {
    case started
    case completed
    case failed
    case cancelled
    case unavailable
}

enum DiagnosticStage: String, CaseIterable, Sendable {
    case input
    case aliasLookup = "alias_lookup"
    case parsing
    case search
    case ranking
    case disposition
    case persistence
}

enum DiagnosticConfidenceBucket: String, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high
}

enum DiagnosticAliasProvenance: String, CaseIterable, Sendable {
    case none
    case builtIn = "built_in"
    case learned
    case manualConfirmation = "manual_confirmation"
    case heuristic
}

/// Closed metadata inputs. Free-form strings, titles, paths, URLs, IDs and localized errors have no case here.
enum DiagnosticMetadata: Hashable, Sendable {
    case httpStatus(Int)
    case businessCode(Int)
    case latencyMilliseconds(Int)
    case durationMilliseconds(Double)
    case retryCount(Int)
    case fallback(Bool)
    case outcome(DiagnosticOutcome)
    case reason(DiagnosticReason)
    case errorCode(Int)
    case host(DiagnosticHost)
    case endpoint(DiagnosticQuarkEndpoint)
    case format(DiagnosticMediaFormat)
    case resolution(DiagnosticResolution)
    case playbackTimeSeconds(Double)
    case playerState(DiagnosticPlayerState)
    case waitingReason(DiagnosticWaitingReason)
    case bufferEmpty(Bool)
    case likelyToKeepUp(Bool)
    case trackCount(Int)
    case audioTrackIndex(Int)
    case route(DiagnosticAudioRoute)
    case status(DiagnosticStatus)
    case stage(DiagnosticStage)
    case candidateCount(Int)
    case confidenceBucket(DiagnosticConfidenceBucket)
    case aliasProvenance(DiagnosticAliasProvenance)
    case focusTarget(DiagnosticFocusTarget)

    fileprivate var persistedEntry: (key: String, value: DiagnosticValue)? {
        switch self {
        case .httpStatus(let value) where (100...599).contains(value):
            return ("httpStatus", .int(value))
        case .businessCode(let value) where (-1_000_000_000...1_000_000_000).contains(value):
            return ("businessCode", .int(value))
        case .latencyMilliseconds(let value) where (0...86_400_000).contains(value):
            return ("latencyMs", .int(value))
        case .durationMilliseconds(let value) where value.isFinite && (0...86_400_000).contains(value):
            return ("durationMs", .double(value))
        case .retryCount(let value) where (0...100).contains(value):
            return ("retryCount", .int(value))
        case .fallback(let value):
            return ("fallback", .bool(value))
        case .outcome(let value):
            return ("outcome", .string(value.rawValue))
        case .reason(let value):
            return ("reason", .string(value.rawValue))
        case .errorCode(let value) where (-1_000_000_000...1_000_000_000).contains(value):
            return ("errorCode", .int(value))
        case .host(let value):
            return ("host", .string(value.rawValue))
        case .endpoint(let value):
            return ("endpoint", .string(value.rawValue))
        case .format(let value):
            return ("format", .string(value.rawValue))
        case .resolution(let value):
            return ("resolution", .string(value.rawValue))
        case .playbackTimeSeconds(let value) where value.isFinite && (0...31_536_000).contains(value):
            return ("playbackTimeSeconds", .double(value))
        case .playerState(let value):
            return ("playerState", .string(value.rawValue))
        case .waitingReason(let value):
            return ("waitingReason", .string(value.rawValue))
        case .bufferEmpty(let value):
            return ("bufferEmpty", .bool(value))
        case .likelyToKeepUp(let value):
            return ("likelyToKeepUp", .bool(value))
        case .trackCount(let value) where (0...1_000).contains(value):
            return ("trackCount", .int(value))
        case .audioTrackIndex(let value) where (0...999).contains(value):
            return ("audioTrack", .int(value))
        case .route(let value):
            return ("route", .string(value.rawValue))
        case .status(let value):
            return ("status", .string(value.rawValue))
        case .stage(let value):
            return ("stage", .string(value.rawValue))
        case .candidateCount(let value) where (0...10_000).contains(value):
            return ("candidateCount", .int(value))
        case .confidenceBucket(let value):
            return ("confidenceBucket", .string(value.rawValue))
        case .aliasProvenance(let value):
            return ("aliasProvenance", .string(value.rawValue))
        case .focusTarget(let value):
            return ("focusTarget", .string(value.rawValue))
        default:
            return nil
        }
    }

    fileprivate static func sanitize(_ metadata: [DiagnosticMetadata]) -> [String: DiagnosticValue] {
        metadata.reduce(into: [:]) { result, field in
            guard let entry = field.persistedEntry else { return }
            result[entry.key] = entry.value
        }
    }

    fileprivate static func sanitizePersisted(_ metadata: [String: DiagnosticValue]) -> [String: DiagnosticValue] {
        metadata.reduce(into: [:]) { result, pair in
            guard let value = sanitizedPersistedValue(key: pair.key, value: pair.value) else { return }
            result[pair.key] = value
        }
    }

    private static func sanitizedPersistedValue(key: String, value: DiagnosticValue) -> DiagnosticValue? {
        switch (key, value) {
        case ("httpStatus", .int(let number)) where (100...599).contains(number):
            return value
        case ("businessCode", .int(let number)) where (-1_000_000_000...1_000_000_000).contains(number):
            return value
        case ("latencyMs", .int(let number)) where (0...86_400_000).contains(number):
            return value
        case ("durationMs", .double(let number)) where number.isFinite && (0...86_400_000).contains(number):
            return value
        case ("retryCount", .int(let number)) where (0...100).contains(number):
            return value
        case ("fallback", .bool), ("bufferEmpty", .bool), ("likelyToKeepUp", .bool):
            return value
        case ("errorCode", .int(let number)) where (-1_000_000_000...1_000_000_000).contains(number):
            return value
        case ("playbackTimeSeconds", .double(let number)) where number.isFinite && (0...31_536_000).contains(number):
            return value
        case ("trackCount", .int(let number)) where (0...1_000).contains(number):
            return value
        case ("audioTrack", .int(let number)) where (0...999).contains(number):
            return value
        case ("candidateCount", .int(let number)) where (0...10_000).contains(number):
            return value
        case ("outcome", .string(let raw)) where DiagnosticOutcome(rawValue: raw) != nil:
            return value
        case ("reason", .string(let raw)) where DiagnosticReason(rawValue: raw) != nil:
            return value
        case ("host", .string(let raw)) where DiagnosticHost(rawValue: raw) != nil:
            return value
        case ("endpoint", .string(let raw)) where DiagnosticQuarkEndpoint(rawValue: raw) != nil:
            return value
        case ("format", .string(let raw)) where DiagnosticMediaFormat(rawValue: raw) != nil:
            return value
        case ("resolution", .string(let raw)) where DiagnosticResolution(rawValue: raw) != nil:
            return value
        case ("playerState", .string(let raw)) where DiagnosticPlayerState(rawValue: raw) != nil:
            return value
        case ("waitingReason", .string(let raw)) where DiagnosticWaitingReason(rawValue: raw) != nil:
            return value
        case ("route", .string(let raw)) where DiagnosticAudioRoute(rawValue: raw) != nil:
            return value
        case ("status", .string(let raw)) where DiagnosticStatus(rawValue: raw) != nil:
            return value
        case ("stage", .string(let raw)) where DiagnosticStage(rawValue: raw) != nil:
            return value
        case ("confidenceBucket", .string(let raw)) where DiagnosticConfidenceBucket(rawValue: raw) != nil:
            return value
        case ("aliasProvenance", .string(let raw)) where DiagnosticAliasProvenance(rawValue: raw) != nil:
            return value
        case ("focusTarget", .string(let raw)) where DiagnosticFocusTarget(rawValue: raw) != nil:
            return value
        default:
            return nil
        }
    }
}

struct DiagnosticRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let sessionID: UUID
    let category: DiagnosticCategory
    let level: DiagnosticLevel
    let event: DiagnosticEvent
    let correlationID: UUID?
    let metadata: [String: DiagnosticValue]

    init(
        id: UUID = UUID(),
        date: Date,
        sessionID: UUID,
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        event: DiagnosticEvent,
        correlationID: UUID? = nil,
        metadata: [String: DiagnosticValue] = [:]
    ) {
        self.id = id
        self.date = date
        self.sessionID = sessionID
        self.category = category
        self.level = level
        self.event = event
        self.correlationID = correlationID
        self.metadata = metadata
    }
}

struct DiagnosticsStoreFailure: Error, Equatable, Sendable {
    enum Operation: String, Sendable {
        case load
        case append
        case clear
        case export
    }

    let operation: Operation
    let code: Int
}

actor DiagnosticsStore {
    nonisolated static let maxFileSize = 10 * 1024 * 1024
    nonisolated static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    nonisolated static let maxVisibleRecords = 500

    nonisolated let fileURL: URL
    nonisolated let initialRecords: [DiagnosticRecord]

    private let exportDirectoryURL: URL
    private let now: @Sendable () -> Date
    private let sessionID: UUID
    private let logger = Logger(subsystem: "org.quarktheater.app", category: "diagnostics")
    private var chronologicalRecords: [DiagnosticRecord]
    private var storedByteCount: Int
    private var storageIsHealthy: Bool
    private var didLoad = false

    init(
        directoryURL: URL? = nil,
        exportDirectoryURL: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let directory = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Diagnostics", isDirectory: true)
        let resolvedFileURL = directory.appendingPathComponent("diagnostics.jsonl")
        let resolvedExportDirectory = exportDirectoryURL ?? FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        self.fileURL = resolvedFileURL
        self.exportDirectoryURL = resolvedExportDirectory
        self.now = now
        self.sessionID = UUID()
        self.chronologicalRecords = []
        self.storedByteCount = 0
        self.storageIsHealthy = true
        self.initialRecords = []
        // Directory creation is intentionally deferred to the actor's first command.
        // DiagnosticsStore() must never perform file I/O on the MainActor.
    }

    nonisolated func makeCorrelationID() -> DiagnosticCorrelationID {
        DiagnosticCorrelationID(value: UUID())
    }

    @discardableResult
    func append(
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        event: DiagnosticEvent,
        correlationID: DiagnosticCorrelationID? = nil,
        metadata: [DiagnosticMetadata] = []
    ) async -> Result<DiagnosticRecord, DiagnosticsStoreFailure> {
        await ensureLoaded()
        let record = DiagnosticRecord(
            date: now(),
            sessionID: sessionID,
            category: category,
            level: level,
            event: event,
            correlationID: correlationID?.value,
            metadata: DiagnosticMetadata.sanitize(metadata)
        )

        guard storageIsHealthy else {
            return .failure(DiagnosticsStoreFailure(operation: .append, code: -1))
        }

        do {
            let line = try Self.encodedLine(record)
            let cutoff = now().addingTimeInterval(-Self.maxAge)
            let hasExpiredRecords = chronologicalRecords.first.map { $0.date < cutoff } ?? false
            let remainsChronological = chronologicalRecords.last.map { $0.date <= record.date } ?? true
            let canAppend = !hasExpiredRecords
                && remainsChronological
                && storedByteCount + line.count <= Self.maxFileSize

            if canAppend {
                try Self.append(line, to: fileURL)
                chronologicalRecords.append(record)
                storedByteCount += line.count
            } else {
                let retained = try Self.retainedChronological(
                    records: chronologicalRecords + [record],
                    now: now()
                )
                let data = try Self.encode(retained)
                try Self.write(data, to: fileURL)
                chronologicalRecords = retained
                storedByteCount = data.count
            }
            return .success(record)
        } catch {
            storageIsHealthy = false
            let code = (error as NSError).code
            logger.warning("diagnostics append failed (code \(code, privacy: .public))")
            return .failure(DiagnosticsStoreFailure(operation: .append, code: code))
        }
    }

    func recent(limit: Int? = nil) async -> [DiagnosticRecord] {
        await ensureLoaded()
        let visible = Self.visibleProjection(from: chronologicalRecords)
        guard let limit else { return visible }
        return Array(visible.prefix(max(0, limit)))
    }

    func clear() async -> Result<Void, DiagnosticsStoreFailure> {
        await ensureLoaded()
        do {
            try Self.write(Data(), to: fileURL)
            chronologicalRecords.removeAll()
            storedByteCount = 0
            storageIsHealthy = true
            return .success(())
        } catch {
            let code = (error as NSError).code
            logger.warning("diagnostics clear failed (code \(code, privacy: .public))")
            return .failure(DiagnosticsStoreFailure(operation: .clear, code: code))
        }
    }

    func export() async -> Result<URL, DiagnosticsStoreFailure> {
        await ensureLoaded()
        do {
            let loaded = try Self.readRecords(from: fileURL).records.map(Self.sanitize)
            let retained = try Self.retainedChronological(records: loaded, now: now())
            let data = try Self.encode(retained)
            try FileManager.default.createDirectory(
                at: exportDirectoryURL,
                withIntermediateDirectories: true
            )
            let formatter = ISO8601DateFormatter()
            let timestamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "-")
            let destination = exportDirectoryURL.appendingPathComponent(
                "diagnostics-\(timestamp)-\(UUID().uuidString.prefix(8)).jsonl"
            )
            try Self.write(data, to: destination)
            return .success(destination)
        } catch {
            let code = (error as NSError).code
            logger.warning("diagnostics export failed (code \(code, privacy: .public))")
            return .failure(DiagnosticsStoreFailure(operation: .export, code: code))
        }
    }

    private func ensureLoaded() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.excludeFromBackup(fileURL.deletingLastPathComponent())
            let readResult = try Self.readRecords(from: fileURL)
            let sanitized = readResult.records.map(Self.sanitize)
            let retained = try Self.retainedChronological(records: sanitized, now: now())
            let canonical = try Self.encode(retained)
            let source = try? Data(contentsOf: fileURL)
            if source != canonical || readResult.recoveredIncompleteTrailingRecord {
                try Self.write(canonical, to: fileURL)
            }
            chronologicalRecords = retained
            storedByteCount = canonical.count
        } catch {
            storageIsHealthy = false
            logger.warning("diagnostics initialization failed (code \((error as NSError).code, privacy: .public))")
        }
    }

    private static func sanitize(_ record: DiagnosticRecord) -> DiagnosticRecord {
        DiagnosticRecord(
            id: record.id,
            date: record.date,
            sessionID: record.sessionID,
            category: record.category,
            level: record.level,
            event: record.event,
            correlationID: record.correlationID,
            metadata: DiagnosticMetadata.sanitizePersisted(record.metadata)
        )
    }

    private struct ReadResult {
        let records: [DiagnosticRecord]
        let recoveredIncompleteTrailingRecord: Bool
    }

    private static func readRecords(from url: URL) throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReadResult(records: [], recoveredIncompleteTrailingRecord: false)
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return ReadResult(records: [], recoveredIncompleteTrailingRecord: false)
        }

        let endsWithNewline = data.last == 0x0A
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if endsWithNewline {
            lines.removeLast()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [DiagnosticRecord] = []
        records.reserveCapacity(lines.count)

        for (index, bytes) in lines.enumerated() {
            guard !bytes.isEmpty else {
                throw DiagnosticsStoreFailure(operation: .load, code: -2)
            }
            do {
                records.append(try decoder.decode(DiagnosticRecord.self, from: Data(bytes)))
            } catch {
                let isLastUnterminatedLine = index == lines.index(before: lines.endIndex) && !endsWithNewline
                if isLastUnterminatedLine, isIncompleteJSONFragment(bytes) {
                    return ReadResult(records: records, recoveredIncompleteTrailingRecord: true)
                }
                throw DiagnosticsStoreFailure(operation: .load, code: (error as NSError).code)
            }
        }

        return ReadResult(records: records, recoveredIncompleteTrailingRecord: false)
    }

    private static func isIncompleteJSONFragment(_ bytes: Data.SubSequence) -> Bool {
        var stack: [UInt8] = []
        var isInsideString = false
        var isEscaped = false

        for byte in bytes {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                isInsideString = true
            case 0x7B, 0x5B:
                stack.append(byte)
            case 0x7D:
                guard stack.last == 0x7B else { return false }
                stack.removeLast()
            case 0x5D:
                guard stack.last == 0x5B else { return false }
                stack.removeLast()
            default:
                break
            }
        }

        return isInsideString || isEscaped || !stack.isEmpty
    }

    private static func retainedChronological(
        records: [DiagnosticRecord],
        now: Date
    ) throws -> [DiagnosticRecord] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let sorted = records.enumerated()
            .filter { $0.element.date >= cutoff }
            .sorted {
                if $0.element.date == $1.element.date { return $0.offset < $1.offset }
                return $0.element.date < $1.element.date
            }
            .map(\.element)

        var retainedNewestFirst: [DiagnosticRecord] = []
        var byteCount = 0
        retainedNewestFirst.reserveCapacity(sorted.count)
        for record in sorted.reversed() {
            let lineSize = try encodedLine(record).count
            guard byteCount + lineSize <= maxFileSize else { break }
            retainedNewestFirst.append(record)
            byteCount += lineSize
        }
        return retainedNewestFirst.reversed()
    }

    private static func visibleProjection(from chronological: [DiagnosticRecord]) -> [DiagnosticRecord] {
        Array(chronological.reversed().prefix(maxVisibleRecords))
    }

    private static func encodedLine(_ record: DiagnosticRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private static func encode<S: Sequence>(_ records: S) throws -> Data where S.Element == DiagnosticRecord {
        var data = Data()
        for record in records {
            data.append(try encodedLine(record))
        }
        return data
    }

    private static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try excludeFromBackup(url)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
