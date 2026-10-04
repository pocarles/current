import XCTest
import CSQLite
@testable import TrafficCore

final class ClockHistoryTests: XCTestCase {
    func testClockCorrectionKeepsRetainedTotalsVisibleAfterDetailPruning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-clock-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_057_600)
        let burst = now.addingTimeInterval(-2 * 86400)
        try await store.record([
            Observation(start: burst, end: burst.addingTimeInterval(60), received: 5_000_000,
                        sent: 1_000, peakDown: 80_000, offlineSeconds: 10)
        ], now: now)
        // A forward clock adjustment expires minute detail. Correcting the
        // clock must still read the retained hourly copy, without adding tiers.
        let future = now.addingTimeInterval(8 * 86400)
        try await store.record([], now: future, events: [(future, "test", "clock change")])
        let result = try await store.aggregate(from: now.addingTimeInterval(-7 * 86400), to: now)
        XCTAssertEqual(result.summary.received, 5_000_000)
        XCTAssertEqual(result.summary.sent, 1_000)
        XCTAssertEqual(result.summary.offline, 10)
        XCTAssertEqual(result.summary.peakDown, 80_000)
        let all = try await store.aggregate(from: nil, to: now)
        XCTAssertEqual(all.summary.received, 5_000_000)
        let chart = try await store.chart(from: now.addingTimeInterval(-7 * 86400), to: now)
        XCTAssertEqual(chart.peak, 80_000)
        let reopened = try HistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let restored = try await reopened.aggregate(from: nil, to: now)
        XCTAssertEqual(restored.summary.received, 5_000_000)
        // Expire the hourly tier too. The daily copy still supplies each byte
        // once after reopening and correcting the clock.
        try await reopened.record([], now: now.addingTimeInterval(200 * 86400))
        let daily = try await reopened.aggregate(from: nil, to: now)
        XCTAssertEqual(daily.summary.received, 5_000_000)
        XCTAssertEqual(daily.summary.offline, 10)
        let dailyChart = try await reopened.chart(from: now.addingTimeInterval(-7 * 86400), to: now)
        XCTAssertEqual(dailyChart.peak, 80_000)
    }
    func testBackwardClockDoesNotScaleSavedOpenBucketDownAndMarksTimingEstimated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-clock-back-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let minute = Date(timeIntervalSince1970: 1_800_057_600)
        try await store.record([Observation(start: minute, end: minute.addingTimeInterval(60), received: 600)], now: minute.addingTimeInterval(60))
        try await store.record([Observation(start: minute.addingTimeInterval(10), end: minute.addingTimeInterval(16), received: 6_000_000)], now: minute.addingTimeInterval(16))
        let result = try await store.aggregate(from: nil, to: minute.addingTimeInterval(16))
        // Both observations now share a bucket. Their individual timing cannot
        // be reconstructed; preserve its saved bytes and disclose the estimate.
        XCTAssertEqual(result.summary.received, 6_000_600)
        XCTAssertTrue(result.boundaryEstimated)
        XCTAssertEqual(result.savedThrough, minute.addingTimeInterval(16))
    }
    func testEventOnlyWriteDoesNotAdvanceAnExistingObservationCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-clock-marker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let date = Date(timeIntervalSince1970: 1_800_057_600)
        try await store.record([], now: date)
        let bootstrap = try await store.lastRecorded(); XCTAssertEqual(bootstrap, date)
        try await store.record([Observation(start: date, end: date.addingTimeInterval(2), received: 100)], now: date.addingTimeInterval(2))
        try await store.record([], now: date.addingTimeInterval(20), events: [(date, "test", "event only")])
        let marker = try await store.lastRecorded(); XCTAssertEqual(marker, date.addingTimeInterval(2))
    }
    func testLegacySchemaThreeUsesSavedHighWaterForPrunedTierSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-clock-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite"), date = Date(timeIntervalSince1970: 1_800_057_600)
        let store = try HistoryStore(url: url)
        try await store.record([Observation(start: date.addingTimeInterval(-2 * 86400), end: date.addingTimeInterval(-2 * 86400 + 60), received: 500)], now: date)
        try await store.record([], now: date.addingTimeInterval(8 * 86400))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "DELETE FROM metadata WHERE key='retention_reference'; UPDATE metadata SET value=\(date.addingTimeInterval(8 * 86400).timeIntervalSince1970) WHERE key='last_recorded';"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let reopened = try HistoryStore(url: url)
        let result = try await reopened.aggregate(from: nil, to: date)
        XCTAssertEqual(result.summary.received, 500)
    }
}
