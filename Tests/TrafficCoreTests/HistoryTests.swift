import XCTest
import CSQLite
@testable import TrafficCore

final class HistoryTests: XCTestCase {
    func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("traffic-test-\(UUID().uuidString)").appendingPathComponent("history.sqlite") }
    func testAggregatesBoundariesExactlyAndPreservesPeakCoverage() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url)
        let date = Date(timeIntervalSince1970: 1_700_006_395)
        let first = Observation(start: date, end: date.addingTimeInterval(70), received: 7001, sent: 14003, peakDown: 1000, peakUp: 2000, offlineSeconds: 20, uncertainSeconds: 5)
        let sleep = Observation(start: first.end, end: first.end.addingTimeInterval(60), coverage: .sleep)
        let gap = Observation(start: sleep.end, end: sleep.end.addingTimeInterval(30), coverage: .unobserved)
        try await store.record([first, sleep, gap], now: gap.end)
        for grain in [60, 3600, 86400] {
            let rows = try await store.rows(grain: grain, limit: 100)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.received }, 7001)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.sent }, 14003)
            XCTAssertEqual(rows.map(\.summary.peakDown).max(), 1000)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.observed }, 70, accuracy: 0.0001)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.sleep }, 60, accuracy: 0.0001)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.unobserved }, 30, accuracy: 0.0001)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.offline }, 20, accuracy: 0.0001)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.uncertain }, 5, accuracy: 0.0001)
        }
        let recorded = try await store.lastRecorded(); XCTAssertEqual(recorded, gap.end)
    }
    func testRetentionRemovesDetailButKeepsHistoricalTotals() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000), old = Date(timeIntervalSince1970: 1_800_000_000 - 200 * 86400)
        try await store.record([Observation(start: old, end: old.addingTimeInterval(1), received: 100, sent: 200, peakDown: 100)], now: old)
        try await store.record([Observation(start: now, end: now.addingTimeInterval(1), received: 10, sent: 20)], now: now)
        let minutes = try await store.rows(grain: 60), hours = try await store.rows(grain: 3600), days = try await store.rows()
        XCTAssertEqual(minutes.reduce(0) { $0 + $1.summary.received }, 10)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.summary.received }, 10)
        XCTAssertEqual(days.reduce(0) { $0 + $1.summary.received }, 110)
        XCTAssertEqual(days.map(\.summary.peakDown).max(), 100)
    }
    func testUTCDateBoundaryAndLocalToday() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url), midnight = Date(timeIntervalSince1970: 1_700_006_400)
        try await store.record([Observation(start: midnight.addingTimeInterval(-30), end: midnight.addingTimeInterval(30), received: 600, sent: 1200)], now: midnight.addingTimeInterval(30))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try await store.today(at: midnight.addingTimeInterval(40), calendar: calendar)
        XCTAssertEqual(today.received, 300); XCTAssertEqual(today.sent, 600)
        let daily = try await store.rows(); XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.received }, 600)
    }
    func testTodayDoesNotIncludeFutureDaysAfterClockChange() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url), day = Date(timeIntervalSince1970: 1_700_006_400)
        try await store.record([
            Observation(start: day, end: day.addingTimeInterval(1), received: 100),
            Observation(start: day.addingTimeInterval(86400), end: day.addingTimeInterval(86401), received: 200)
        ], now: day.addingTimeInterval(86401))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let summary = try await store.today(at: day, calendar: calendar)
        XCTAssertEqual(summary.received, 100)
    }
    func testTenYearsPreserveDailyTotalsPeaksAndCoverageAfterDetailExpires() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url)
        let day = Date(timeIntervalSince1970: 1_800_057_600) // exact UTC midnight
        let count = 3653
        var observations: [Observation] = []
        for i in 0..<count {
            let start = day.addingTimeInterval(-Double(i) * 86400)
            observations.append(Observation(start: start, end: start.addingTimeInterval(60), received: 1001, sent: 500, peakDown: 42, peakUp: 21))
            observations.append(Observation(start: start.addingTimeInterval(60), end: start.addingTimeInterval(120), received: 2003, sent: 400, peakDown: 70, peakUp: 15, offlineSeconds: 10, uncertainSeconds: 20))
            observations.append(Observation(start: start.addingTimeInterval(120), end: start.addingTimeInterval(180), coverage: .sleep))
            observations.append(Observation(start: start.addingTimeInterval(180), end: start.addingTimeInterval(240), coverage: .unobserved))
            observations.append(Observation(start: start.addingTimeInterval(240), end: start.addingTimeInterval(300), coverage: .appGap))
        }
        try await store.record(observations, now: day.addingTimeInterval(360))
        let daily = try await store.rows(limit: 40000), hours = try await store.rows(grain: 3600, limit: 40000), minutes = try await store.rows(grain: 60, limit: 40000)
        XCTAssertEqual(daily.count, count)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.received }, UInt64(count * 3004))
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.sent }, UInt64(count * 900))
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.offline }, Double(count * 10), accuracy: 0.001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.uncertain }, Double(count * 20), accuracy: 0.001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.observed }, Double(count * 120), accuracy: 0.001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.sleep }, Double(count * 60), accuracy: 0.001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.unobserved }, Double(count * 60), accuracy: 0.001)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.summary.appGap }, Double(count * 60), accuracy: 0.001)
        XCTAssertTrue(daily.allSatisfy { $0.summary.peakDown == 70 && $0.summary.peakUp == 21 })
        let all = try await store.aggregate(from: nil, to: day.addingTimeInterval(360))
        XCTAssertEqual(all.summary.received, UInt64(count * 3004)); XCTAssertEqual(all.summary.sent, UInt64(count * 900))
        XCTAssertEqual(all.summary.peakDown, 70); XCTAssertEqual(all.summary.peakUp, 21)
        XCTAssertEqual(all.summary.sleep, Double(count * 60)); XCTAssertEqual(all.summary.appGap, Double(count * 60))
        XCTAssertEqual(all.summary.unobserved, Double(count * 60)); XCTAssertEqual(all.summary.offline, Double(count * 10))
        XCTAssertEqual(hours.count, 180)
        XCTAssertEqual(minutes.count, 7 * 5)
        let backup = url.deletingLastPathComponent().appendingPathComponent("ten-year-backup.sqlite")
        try await store.backup(to: backup)
        let restored = try HistoryStore(url: backup), restoredDays = try await restored.rows(limit: 40000)
        XCTAssertEqual(restoredDays.count, count)
        XCTAssertEqual(restoredDays.reduce(0) { $0 + $1.summary.received }, UInt64(count * 3004))
        let csv = url.deletingLastPathComponent().appendingPathComponent("ten-year-export.csv")
        try await store.exportCSV(to: csv)
        let dataRows = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").dropFirst()
        XCTAssertEqual(dataRows.count, count)
        XCTAssertEqual(dataRows.reduce(UInt64(0)) { $0 + UInt64($1.split(separator: ",", omittingEmptySubsequences: false)[2])! }, UInt64(count * 3004))
    }
    func testEventCapRemainsExactWithinOneDay() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url), day = Date(timeIntervalSince1970: 1_800_057_600)
        let events: [RecordedEvent] = (0..<50005).map { (day, "test", "Event \($0)") }
        try await store.record([], now: day, events: events)
        try await store.record([], now: day.addingTimeInterval(1), events: [(day, "latest", "Latest retained event")])
        let retained = try await store.events(limit: 50000)
        XCTAssertEqual(retained.count, 50000)
        XCTAssertEqual(retained.first?.kind, "latest")
        // A backup checked through SQLite proves there are no hidden rows beyond the API limit.
        let backup = url.deletingLastPathComponent().appendingPathComponent("events.sqlite")
        try await store.backup(to: backup)
        var db: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backup.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK, db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle")
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 50000)
    }
    func testV1MigrationPreservesExistingDataAndFutureVersionRejected() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE buckets(grain INTEGER,start INTEGER,received INTEGER,sent INTEGER,peak_down REAL,peak_up REAL,observed REAL,sleep REAL,unobserved REAL,offline REAL,PRIMARY KEY(grain,start));
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value REAL);
        CREATE TABLE events(id INTEGER PRIMARY KEY,date REAL,kind TEXT,detail TEXT);
        INSERT INTO buckets VALUES(86400,1699920000,123,456,12,34,60,0,0,0);
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = try HistoryStore(url: url), rows = try await store.rows()
        XCTAssertEqual(rows.first?.summary.received, 123); XCTAssertEqual(rows.first?.summary.uncertain, 0); XCTAssertEqual(rows.first?.summary.appGap, 0)
        let futureURL = url.deletingLastPathComponent().appendingPathComponent("future.sqlite")
        XCTAssertEqual(sqlite3_open(futureURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil); sqlite3_close(db)
        XCTAssertThrowsError(try HistoryStore(url: futureURL))
    }
    func testV2MigrationPreservesLegacyMissingTimeWithoutInventingAppGaps() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE buckets(grain INTEGER,start INTEGER,received INTEGER,sent INTEGER,peak_down REAL,peak_up REAL,observed REAL,sleep REAL,unobserved REAL,offline REAL,uncertain REAL,PRIMARY KEY(grain,start));
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value REAL);
        CREATE TABLE events(id INTEGER PRIMARY KEY,date REAL,kind TEXT,detail TEXT);
        INSERT INTO buckets VALUES(86400,1699920000,123,456,12,34,60,10,20,5,3);
        PRAGMA user_version=2;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = try HistoryStore(url: url), rows = try await store.rows()
        XCTAssertEqual(rows.first?.summary.received, 123)
        XCTAssertEqual(rows.first?.summary.unobserved, 20)
        XCTAssertEqual(rows.first?.summary.appGap, 0)
        XCTAssertEqual(rows.first?.summary.uncertain, 3)
    }
    func testBackupAndCSVIncludeEventsAndCannotOverwriteActiveDB() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url), date = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record([Observation(start: date, end: date.addingTimeInterval(1), received: 123, sent: 456)], now: date,
                               events: [(date, "offline", "Quoted \"event\", details")])
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try await store.backup(to: backup)
        let restored = try HistoryStore(url: backup), rows = try await restored.rows(), events = try await restored.events()
        XCTAssertEqual(rows.first?.summary.received, 123); XCTAssertEqual(events.count, 1)
        do { try await store.backup(to: url); XCTFail("Active database must be protected") } catch {}
        do { try await store.backup(to: backup); XCTFail("Existing backup must be protected") } catch {}
        let csv = url.deletingLastPathComponent().appendingPathComponent("export.csv")
        try await store.exportCSV(to: csv)
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.contains("download_bytes")); XCTAssertTrue(text.contains(",123,456,"))
        XCTAssertTrue(text.contains("\"Quoted \"\"event\"\", details\""))
    }
    func testLongSleepGapClipsOldDetailAndPreservesDailyGap() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url), now = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.record([Observation(start: now.addingTimeInterval(-10 * 86400), end: now, coverage: .sleep)], now: now)
        let minutes = try await store.rows(grain: 60, limit: 40000), days = try await store.rows()
        XCTAssertLessThanOrEqual(minutes.count, 10081)
        XCTAssertEqual(minutes.reduce(0) { $0 + $1.summary.sleep }, 7 * 86400, accuracy: 0.001)
        XCTAssertEqual(days.reduce(0) { $0 + $1.summary.sleep }, 10 * 86400, accuracy: 0.001)
        XCTAssertEqual(days.reduce(0) { $0 + $1.summary.received }, 0)
    }
    func testFailedBackupLeavesNoDestinationOrTemporaryFileAndCanRetry() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url), date = Date(timeIntervalSince1970: 1_800_057_600)
        try await store.record([Observation(start: date, end: date.addingTimeInterval(60), received: 123)], now: date.addingTimeInterval(60))
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        do {
            try await store.backup(to: backup, step: { _ in SQLITE_IOERR })
            XCTFail("Injected backup failure must fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".Traffic-backup-") })
        try await store.backup(to: backup)
        let restored = try HistoryStore(url: backup), rows = try await restored.rows()
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.received }, 123)
    }
    func testBackupRefusesDestinationCreatedDuringCopy() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try HistoryStore(url: url)
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        let existing = Data("Do not overwrite".utf8)
        do {
            try await store.backup(to: backup, step: { pointer in
                try! existing.write(to: backup)
                return sqlite3_backup_step(pointer, -1)
            })
            XCTFail("Racing existing destination must be protected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: backup), existing)
    }
}
