import Combine
import XCTest
@testable import QuarkTheater

private let diagnosticsTestNow = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
final class DiagnosticsStoreTests: XCTestCase {
    private let fixedNow = diagnosticsTestNow

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore(now: Date? = nil) throws -> (DiagnosticsStore, URL) {
        let root = try makeRoot()
        let exportDirectory = root.appendingPathComponent("Exports", isDirectory: true)
        return (
            DiagnosticsStore(
                directoryURL: root,
                exportDirectoryURL: exportDirectory,
                now: { now ?? diagnosticsTestNow }
            ),
            root
        )
    }

    @discardableResult
    private func append(
        to store: DiagnosticsStore,
        category: DiagnosticCategory = .cloud,
        level: DiagnosticLevel = .info,
        event: DiagnosticEvent = .requestCompleted,
        correlationID: DiagnosticCorrelationID? = nil,
        metadata: [DiagnosticMetadata] = []
    ) async throws -> DiagnosticRecord {
        try await store.append(
            category: category,
            level: level,
            event: event,
            correlationID: correlationID,
            metadata: metadata
        ).get()
    }

    func testEventsAreClosedAndCorrelationsAreStoreGeneratedUUIDs() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(DiagnosticEvent(rawValue: "playback.account-123-title"))

        let correlation = store.makeCorrelationID()
        let first = try await append(to: store, event: .requestCompleted, correlationID: correlation)
        let second = try await append(to: store, event: .requestFailed, correlationID: correlation)

        let firstID = try XCTUnwrap(first.correlationID)
        XCTAssertEqual(firstID, second.correlationID)
        XCTAssertNotNil(UUID(uuidString: firstID.uuidString))
        XCTAssertNotEqual(firstID.uuidString, "account-123")
    }

    func testTypedMetadataRejectsInvalidRangesAndPersistsOnlyClosedStringEnums() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await append(
            to: store,
            level: .error,
            event: .requestFailed,
            metadata: [
                .httpStatus(403),
                .retryCount(-1),
                .playbackTimeSeconds(.infinity),
                .outcome(.failed),
                .reason(.authenticationRequired),
                .audioTrackIndex(-4)
            ]
        )

        XCTAssertEqual(record.metadata["httpStatus"], .int(403))
        XCTAssertEqual(record.metadata["outcome"], .string("failed"))
        XCTAssertEqual(record.metadata["reason"], .string("authentication_required"))
        XCTAssertNil(record.metadata["retryCount"])
        XCTAssertNil(record.metadata["playbackTimeSeconds"])
        XCTAssertNil(record.metadata["audioTrack"])
    }

    func testExportResanitizesAllowedKeyValuesReadFromDisk() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let unsafe = DiagnosticRecord(
            date: fixedNow,
            sessionID: UUID(),
            category: .cloud,
            level: .error,
            event: .requestFailed,
            metadata: [
                "httpStatus": .int(403),
                "outcome": .string("权力的游戏"),
                "reason": .string("服务器返回原始错误"),
                "host": .string("account-123.example.test"),
                "bufferEmpty": .bool(false)
            ]
        )
        try writeJSONL([unsafe], to: store.fileURL)

        let exportURL = try await store.export().get()
        let exported = try Data(contentsOf: exportURL)
        let text = try XCTUnwrap(String(data: exported, encoding: .utf8))
        XCTAssertFalse(text.contains("权力的游戏"))
        XCTAssertFalse(text.contains("服务器返回原始错误"))
        XCTAssertFalse(text.contains("account-123"))

        let record = try XCTUnwrap(try decodeJSONL(exported).first)
        XCTAssertEqual(record.metadata, [
            "bufferEmpty": .bool(false),
            "httpStatus": .int(403)
        ])
    }

    func testAppendsJSONLWithoutReplacingExistingFile() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await append(to: store, category: .playback, event: .started)
        let firstData = try Data(contentsOf: store.fileURL)
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let firstFileNumber = firstAttributes[.systemFileNumber] as? NSNumber

        _ = try await append(to: store, category: .audio, level: .warning, event: .silentMarker)
        let secondData = try Data(contentsOf: store.fileURL)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)

        XCTAssertTrue(secondData.starts(with: firstData))
        XCTAssertGreaterThan(secondData.count, firstData.count)
        XCTAssertEqual(secondAttributes[.systemFileNumber] as? NSNumber, firstFileNumber)
        let recentEvents = await store.recent().map(\.event)
        XCTAssertEqual(recentEvents, [.silentMarker, .started])
    }

    func testStructuredProjectionIsObservableAndBoundedTo500Records() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        for _ in 0..<501 {
            _ = try await append(to: store)
        }
        let reloaded = DiagnosticsStore(
            directoryURL: root,
            exportDirectoryURL: root.appendingPathComponent("Exports", isDirectory: true),
            now: { diagnosticsTestNow }
        )
        let diagnostics = Diagnostics(store: reloaded)
        await diagnostics.waitForPendingOperations()
        XCTAssertEqual(diagnostics.records.count, DiagnosticsStore.maxVisibleRecords)

        let published = expectation(description: "structured records published")
        var cancellable: AnyCancellable?
        cancellable = diagnostics.$records.dropFirst().sink { records in
            if records.first?.event == .silentMarker, records.count == DiagnosticsStore.maxVisibleRecords {
                published.fulfill()
            }
        }
        diagnostics.record(category: .audio, level: .notice, event: .silentMarker)
        await fulfillment(of: [published], timeout: 5)
        cancellable?.cancel()
    }

    func testRetentionRemovesRecordsOlderThan14Days() async throws {
        let oldNow = Date(timeIntervalSince1970: 1_600_000_000)
        let (store, root) = try makeStore(now: oldNow)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await append(to: store)

        let reloaded = DiagnosticsStore(
            directoryURL: root,
            now: { oldNow.addingTimeInterval(DiagnosticsStore.maxAge + 1) }
        )

        let recent = await reloaded.recent()
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: reloaded.fileURL).count, 0)
    }

    func testRetentionEnforcesActual10MiBCapWithoutCreatingBackups() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("diagnostics.jsonl")
        let record = DiagnosticRecord(
            date: fixedNow,
            sessionID: UUID(),
            category: .playback,
            level: .info,
            event: .started,
            metadata: [
                "httpStatus": .int(200),
                "durationMs": .double(12.0),
                "outcome": .string("succeeded"),
                "reason": .string("none"),
                "format": .string("hls"),
                "resolution": .string("full_hd"),
                "playerState": .string("playing"),
                "waitingReason": .string("none"),
                "route": .string("hdmi"),
                "stage": .string("persistence"),
                "confidenceBucket": .string("high"),
                "aliasProvenance": .string("built_in")
            ]
        )
        let line = try encodedLine(record)
        var oversized = Data(capacity: DiagnosticsStore.maxFileSize + line.count)
        while oversized.count <= DiagnosticsStore.maxFileSize {
            oversized.append(line)
        }
        try oversized.write(to: fileURL)
        XCTAssertGreaterThan(try Data(contentsOf: fileURL).count, DiagnosticsStore.maxFileSize)

        let store = DiagnosticsStore(directoryURL: root, now: { diagnosticsTestNow })

        let recent = await store.recent()
        XCTAssertLessThanOrEqual(try Data(contentsOf: store.fileURL).count, DiagnosticsStore.maxFileSize)
        XCTAssertEqual(recent.count, DiagnosticsStore.maxVisibleRecords)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["diagnostics.jsonl"])
    }

    func testFocusTargetMetadataIsAllowlistedAndPersisted() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await store.append(category: .navigation, level: .debug, event: .focusChanged,
                                        metadata: [.focusTarget(.settings)])
        let record = try result.get()
        XCTAssertEqual(record.event, .focusChanged)
        XCTAssertEqual(record.metadata["focusTarget"], .string("settings"))
        let recent = await store.recent()
        XCTAssertEqual(recent.count, 1)
    }

    func testFocusTransitionsDeduplicateAndRateLimitWithoutPersistingLabels() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Diagnostics(store: store)
        await diagnostics.waitForPendingOperations()
        let start = diagnosticsTestNow

        diagnostics.recordFocusTransition(.fileBrowserRow, now: start)
        diagnostics.recordFocusTransition(.fileBrowserRow, now: start.addingTimeInterval(1.0))
        diagnostics.recordFocusTransition(.folderRow, now: start.addingTimeInterval(0.1))
        diagnostics.recordFocusTransition(.folderRow, now: start.addingTimeInterval(0.21))
        await diagnostics.waitForPendingOperations()

        XCTAssertEqual(diagnostics.records.map(\.event), [.focusChanged, .focusChanged])
        XCTAssertEqual(diagnostics.records.map { $0.metadata["focusTarget"] }, [
            .string("folder_row"), .string("file_browser_row")
        ])
        let raw = try String(contentsOf: store.fileURL)
        XCTAssertFalse(raw.contains("file-"))
        XCTAssertFalse(raw.contains("title"))
    }

    func testFocusTransitionsRateLimitRapidAlternatingRegionsGlobally() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Diagnostics(store: store)
        await diagnostics.waitForPendingOperations()
        let start = diagnosticsTestNow

        diagnostics.recordFocusTransition(.fileBrowserRow, now: start)
        diagnostics.recordFocusTransition(.fileBrowserRow, now: start.addingTimeInterval(1.0))
        diagnostics.recordFocusTransition(.folderRow, now: start.addingTimeInterval(0.1))
        diagnostics.recordFocusTransition(.folderRow, now: start.addingTimeInterval(0.21))
        diagnostics.recordFocusTransition(.folderRow, now: start.addingTimeInterval(1.0))
        await diagnostics.waitForPendingOperations()

        XCTAssertEqual(diagnostics.records.count, 2)
        XCTAssertEqual(diagnostics.records.map { $0.metadata["focusTarget"] }, [
            .string("folder_row"), .string("file_browser_row")
        ])
    }

    func testJSONRoundTripPreservesIntegralDoubleAndIntCases() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await append(
            to: store,
            metadata: [
                .businessCode(12),
                .durationMilliseconds(12.0)
            ]
        )
        let reloaded = DiagnosticsStore(directoryURL: root, now: { diagnosticsTestNow })
        let recent = await reloaded.recent()
        let record = try XCTUnwrap(recent.first)

        XCTAssertEqual(record.metadata["businessCode"], .int(12))
        XCTAssertEqual(record.metadata["durationMs"], .double(12.0))
    }

    func testRecoversIncompleteTrailingJSONLObject() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("diagnostics.jsonl")
        let valid = DiagnosticRecord(
            date: fixedNow,
            sessionID: UUID(),
            category: .navigation,
            level: .info,
            event: .focusChanged
        )
        var data = try encodedLine(valid)
        data.append(Data("{\"truncated\":true".utf8))
        try data.write(to: fileURL)

        let store = DiagnosticsStore(directoryURL: root, now: { diagnosticsTestNow })

        let recentEvents = await store.recent().map(\.event)
        XCTAssertEqual(recentEvents, [.focusChanged])
        XCTAssertEqual(try Data(contentsOf: fileURL), try encodedLine(valid))
    }

    func testDoesNotSilentlyDropMalformedInteriorJSONLRecord() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("diagnostics.jsonl")
        let valid = DiagnosticRecord(
            date: fixedNow,
            sessionID: UUID(),
            category: .navigation,
            level: .info,
            event: .focusChanged
        )
        var original = try encodedLine(valid)
        original.append(Data("{malformed}\n".utf8))
        original.append(try encodedLine(valid))
        try original.write(to: fileURL)

        let store = DiagnosticsStore(directoryURL: root, now: { diagnosticsTestNow })

        let recent = await store.recent()
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testDoesNotTreatCompleteMalformedTrailingJSONAsInterruptedWrite() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("diagnostics.jsonl")
        let valid = DiagnosticRecord(
            date: fixedNow,
            sessionID: UUID(),
            category: .navigation,
            level: .info,
            event: .focusChanged
        )
        var original = try encodedLine(valid)
        original.append(Data("{malformed}".utf8))
        try original.write(to: fileURL)

        let store = DiagnosticsStore(directoryURL: root, now: { diagnosticsTestNow })

        let recent = await store.recent()
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testFailedDiskClearKeepsInMemoryProjection() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let persisted = try await append(to: store)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

        let result = await store.clear()

        if case .success = result {
            XCTFail("clear unexpectedly succeeded when the diagnostics file URL is a directory")
        }
        let recentIDs = await store.recent().map(\.id)
        XCTAssertEqual(recentIDs, [persisted.id])
    }

    func testDiagnosticsCommandsPreserveRecordThenClearOrder() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Diagnostics(store: store)

        diagnostics.record(category: .playback, level: .info, event: .started)
        diagnostics.clear()
        await diagnostics.waitForPendingOperations()

        XCTAssertTrue(diagnostics.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data())
    }

    func testDiagnosticsCommandsPreserveClearThenRecordOrder() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Diagnostics(store: store)

        diagnostics.clear()
        diagnostics.record(category: .playback, level: .info, event: .started)
        await diagnostics.waitForPendingOperations()

        XCTAssertEqual(diagnostics.records.map(\.event), [.started])
    }

    func testDiagnosticsClearResultCompletesAfterDurableClear() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Diagnostics(store: store)
        diagnostics.record(category: .playback, level: .info, event: .started)

        let result = await diagnostics.clear().value

        if case .failure(let failure) = result {
            XCTFail("clear unexpectedly failed: \(failure)")
        }
        XCTAssertTrue(diagnostics.records.isEmpty)
        let recent = await store.recent()
        XCTAssertEqual(recent.count, 0)
    }

    func testDiagnosticsStorageIsExcludedFromBackup() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await store.recent()

        let directoryValues = try store.fileURL.deletingLastPathComponent().resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        let fileValues = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertNotNil(directoryValues.isExcludedFromBackup)
        XCTAssertNotNil(fileValues.isExcludedFromBackup)
        XCTAssertEqual(directoryValues.isExcludedFromBackup, true)
        XCTAssertEqual(fileValues.isExcludedFromBackup, true)
    }
}

private func encodedLine(_ record: DiagnosticRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(record)
    data.append(0x0A)
    return data
}

private func writeJSONL(_ records: [DiagnosticRecord], to url: URL) throws {
    var data = Data()
    for record in records {
        data.append(try encodedLine(record))
    }
    try data.write(to: url)
}

private func decodeJSONL(_ data: Data) throws -> [DiagnosticRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: 0x0A).map {
        try decoder.decode(DiagnosticRecord.self, from: Data($0))
    }
}
