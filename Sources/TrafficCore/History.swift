import Foundation
import CSQLite
import Darwin

public struct HistorySummary: Sendable, Equatable {
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public var peakDown: Double = 0
    public var peakUp: Double = 0
    public var observed: Double = 0
    public var sleep: Double = 0
    public var unobserved: Double = 0
    public var appGap: Double = 0
    public var offline: Double = 0
    public var uncertain: Double = 0
    public init() {}
}
public struct HistoryRow: Sendable, Identifiable {
    public var id: Int64 { start }
    public var start: Int64
    public var summary: HistorySummary
}
public struct HistoryEvent: Sendable, Identifiable {
    public var id: Int64
    public var date: Date
    public var kind: String
    public var detail: String
}
public struct HistoryError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ text: String) { description = text }
}

// Accessed only by HistoryStore's actor. Owns C pointers and always finalizes statements.
private final class Database: @unchecked Sendable {
    var handle: OpaquePointer?
    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open history"
            sqlite3_close(handle); handle = nil; throw HistoryError(message)
        }
        sqlite3_busy_timeout(handle, 1000)
    }
    deinit { close() }
    func close() { sqlite3_close(handle); handle = nil }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func error() -> HistoryError { HistoryError(String(cString: sqlite3_errmsg(handle))) }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int64(statement, 0)
    }
}

public actor HistoryStore: HistoryRepository {
    private let db: Database
    public let url: URL
    public static let schemaVersion = 3
    public static let minuteRetention: Double = 7 * 86400
    public static let hourRetention: Double = 180 * 86400
    public static let dayRetention: Double = 100 * 365.25 * 86400
    private var lastPruneDay: Int64 = -1
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try Database(path: url.path)
        let version = try db.scalar("PRAGMA user_version")
        guard version <= Self.schemaVersion else { throw HistoryError("History was written by a newer Current version. No changes made.") }
        try db.exec("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=128; PRAGMA journal_size_limit=1048576; PRAGMA max_page_count=16384;")
        try db.exec("BEGIN IMMEDIATE")
        do {
            if version == 0 {
                try db.exec("""
                CREATE TABLE buckets (
                  grain INTEGER NOT NULL, start INTEGER NOT NULL,
                  received INTEGER NOT NULL DEFAULT 0, sent INTEGER NOT NULL DEFAULT 0,
                  peak_down REAL NOT NULL DEFAULT 0, peak_up REAL NOT NULL DEFAULT 0,
                  observed REAL NOT NULL DEFAULT 0, sleep REAL NOT NULL DEFAULT 0,
                  unobserved REAL NOT NULL DEFAULT 0, offline REAL NOT NULL DEFAULT 0,
                  PRIMARY KEY(grain,start)
                ) WITHOUT ROWID;
                CREATE TABLE events (id INTEGER PRIMARY KEY, date REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL);
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value REAL NOT NULL) WITHOUT ROWID;
                PRAGMA user_version=1;
                """)
            }
            if version < 2 { try db.exec("ALTER TABLE buckets ADD COLUMN uncertain REAL NOT NULL DEFAULT 0; PRAGMA user_version=2;") }
            if version < 3 { try db.exec("ALTER TABLE buckets ADD COLUMN app_gap REAL NOT NULL DEFAULT 0; PRAGMA user_version=3;") }
            try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
    }
    public func lastRecorded() throws -> Date? {
        let statement = try db.prepare("SELECT value FROM metadata WHERE key='last_recorded'")
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        case SQLITE_DONE: return nil
        default: throw db.error()
        }
    }
    public func record(_ observations: [Observation], now: Date = Date(), events: [(Date, String, String)] = [], connectivity: ConnectivityUpdate = .unchanged) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            let statement = try db.prepare("""
            INSERT INTO buckets(grain,start,received,sent,peak_down,peak_up,observed,sleep,unobserved,offline,uncertain,app_gap)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(grain,start) DO UPDATE SET
            received=received+excluded.received,sent=sent+excluded.sent,
            peak_down=MAX(peak_down,excluded.peak_down),peak_up=MAX(peak_up,excluded.peak_up),
            observed=observed+excluded.observed,sleep=sleep+excluded.sleep,
            unobserved=unobserved+excluded.unobserved,offline=offline+excluded.offline,uncertain=uncertain+excluded.uncertain,app_gap=app_gap+excluded.app_gap;
            """)
            defer { sqlite3_finalize(statement) }
            for observation in observations where observation.duration > 0 {
                for (grain, retention) in [(60, Self.minuteRetention), (3600, Self.hourRetention), (86400, Self.dayRetention)] {
                    var cursor = max(observation.start.timeIntervalSince1970, now.timeIntervalSince1970 - retention)
                    let end = observation.end.timeIntervalSince1970
                    var allocatedDown: UInt64 = 0, allocatedUp: UInt64 = 0
                    // Exact totals for observations within retention. Boundary clipping is proportional.
                    let clipped = cursor > observation.start.timeIntervalSince1970
                    while cursor < end {
                        let bucket = Int64(floor(cursor / Double(grain))) * Int64(grain)
                        let next = min(end, Double(bucket + Int64(grain)))
                        let seconds = next - cursor
                        let fraction = seconds / observation.duration
                        let down = next == end && !clipped ? observation.received - allocatedDown : UInt64((Double(observation.received) * fraction).rounded(.down))
                        let up = next == end && !clipped ? observation.sent - allocatedUp : UInt64((Double(observation.sent) * fraction).rounded(.down))
                        allocatedDown += down; allocatedUp += up
                        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                        sqlite3_bind_int(statement, 1, Int32(grain)); sqlite3_bind_int64(statement, 2, bucket)
                        sqlite3_bind_int64(statement, 3, Int64(clamping: down)); sqlite3_bind_int64(statement, 4, Int64(clamping: up))
                        sqlite3_bind_double(statement, 5, observation.peakDown); sqlite3_bind_double(statement, 6, observation.peakUp)
                        sqlite3_bind_double(statement, 7, observation.coverage == .observed ? seconds : 0)
                        sqlite3_bind_double(statement, 8, observation.coverage == .sleep ? seconds : 0)
                        sqlite3_bind_double(statement, 9, [.partial, .unobserved].contains(observation.coverage) ? seconds : 0)
                        sqlite3_bind_double(statement, 10, min(seconds, max(0, observation.offlineSeconds * fraction)))
                        sqlite3_bind_double(statement, 11, min(seconds, max(0, observation.uncertainSeconds * fraction)))
                        sqlite3_bind_double(statement, 12, observation.coverage == .appGap ? seconds : 0)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw db.error() }
                        cursor = next
                    }
                }
            }
            if case .replace(let evidence) = connectivity {
                try db.exec("DELETE FROM metadata WHERE key IN ('online_since','online_seconds','online_gaps')")
                if let evidence {
                    guard evidence.since.timeIntervalSince1970.isFinite, evidence.seconds.isFinite, evidence.seconds >= 0 else {
                        throw HistoryError("Invalid connectivity evidence")
                    }
                    let insert = try db.prepare("INSERT INTO metadata(key,value) VALUES(?,?)")
                    defer { sqlite3_finalize(insert) }
                    for (key, value) in [("online_since", evidence.since.timeIntervalSince1970),
                                         ("online_seconds", evidence.seconds), ("online_gaps", evidence.hasGaps ? 1.0 : 0.0)] {
                        sqlite3_reset(insert)
                        sqlite3_bind_text(insert, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        sqlite3_bind_double(insert, 2, value)
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw db.error() }
                    }
                }
            }
            for (date, kind, detail) in events { try addEvent(date: date, kind: kind, detail: detail) }
            if !events.isEmpty {
                // Enforce the documented cap on each event batch, including within the same day.
                try db.exec("DELETE FROM events WHERE id <= (SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET 50000)")
            }
            // Do not claim coverage up to 'now' if the caller has pending samples.
            // Bootstrap a new store at launch; later event-only writes must
            // not skip the interval after the last actual observation.
            var latest = observations.filter({ $0.duration > 0 }).map(\.end).max()
            if latest == nil, try lastRecorded() == nil { latest = now }
            if let latest {
                let checkpoint = try db.prepare("INSERT INTO metadata(key,value) VALUES('last_recorded',?) ON CONFLICT(key) DO UPDATE SET value=MAX(value,excluded.value)")
                defer { sqlite3_finalize(checkpoint) }
                sqlite3_bind_double(checkpoint, 1, latest.timeIntervalSince1970)
                guard sqlite3_step(checkpoint) == SQLITE_DONE else { throw db.error() }
            }
            let day = Int64(now.timeIntervalSince1970 / 86400)
            if day != lastPruneDay {
                for (grain, retention) in [(60, Self.minuteRetention), (3600, Self.hourRetention), (86400, Self.dayRetention)] {
                    let threshold = Int64(now.timeIntervalSince1970 - retention) / Int64(grain) * Int64(grain)
                    try db.exec("DELETE FROM buckets WHERE grain=\(grain) AND start<\(threshold)")
                }
                // Detail removed by a forward clock adjustment cannot return
                // when the clock is corrected. Persist the pruning reference
                // in the same transaction so queries select surviving tiers.
                let retention = try db.prepare("INSERT INTO metadata(key,value) VALUES('retention_reference',?) ON CONFLICT(key) DO UPDATE SET value=MAX(value,excluded.value)")
                defer { sqlite3_finalize(retention) }
                sqlite3_bind_double(retention, 1, now.timeIntervalSince1970)
                guard sqlite3_step(retention) == SQLITE_DONE else { throw db.error() }
            }
            try db.exec("COMMIT")
            if day != lastPruneDay { lastPruneDay = day; try? db.exec("PRAGMA incremental_vacuum(200)") }
        } catch { try? db.exec("ROLLBACK"); throw error }
    }
    private func addEvent(date: Date, kind: String, detail: String) throws {
        let statement = try db.prepare("INSERT INTO events(date,kind,detail) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 2, kind, -1, transient)
        sqlite3_bind_text(statement, 3, String(detail.prefix(512)), -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw db.error() }
    }
    public func rows(grain: Int = 86400, since: Date = .distantPast, limit: Int = 366) throws -> [HistoryRow] {
        guard [60, 3600, 86400].contains(grain) else { throw HistoryError("Unknown history interval") }
        let statement = try db.prepare("SELECT start,received,sent,peak_down,peak_up,observed,sleep,unobserved,offline,uncertain,app_gap FROM buckets WHERE grain=? AND start>=? ORDER BY start DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(grain)); sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970))
        sqlite3_bind_int(statement, 3, Int32(min(40000, max(1, limit))))
        var result: [HistoryRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw db.error() }
            var summary = HistorySummary()
            summary.received = UInt64(max(0, sqlite3_column_int64(statement, 1)))
            summary.sent = UInt64(max(0, sqlite3_column_int64(statement, 2)))
            summary.peakDown = sqlite3_column_double(statement, 3); summary.peakUp = sqlite3_column_double(statement, 4)
            summary.observed = sqlite3_column_double(statement, 5); summary.sleep = sqlite3_column_double(statement, 6)
            summary.unobserved = sqlite3_column_double(statement, 7); summary.offline = sqlite3_column_double(statement, 8)
            summary.uncertain = sqlite3_column_double(statement, 9); summary.appGap = sqlite3_column_double(statement, 10)
            result.append(HistoryRow(start: sqlite3_column_int64(statement, 0), summary: summary))
        }
        return result
    }
    public func onlineEvidence() throws -> OnlineEvidence? {
        let statement = try db.prepare("SELECT key,value FROM metadata WHERE key IN ('online_since','online_seconds','online_gaps')")
        defer { sqlite3_finalize(statement) }
        var values: [String: Double] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw db.error() }
            values[String(cString: sqlite3_column_text(statement, 0))] = sqlite3_column_double(statement, 1)
        }
        guard let since = values["online_since"], let seconds = values["online_seconds"], since.isFinite,
              seconds.isFinite, seconds >= 0 else { return nil }
        return OnlineEvidence(since: Date(timeIntervalSince1970: since), seconds: seconds, hasGaps: values["online_gaps"] == 1)
    }
    public func recentGraph(ending end: Date) throws -> [GraphPoint] {
        let lower = end.addingTimeInterval(-LiveGraph.span)
        let marker = min(end, try lastRecorded() ?? end)
        // Only 61 retained minute buckets, including the clipped first minute.
        let statement = try db.prepare("""
        SELECT start,peak_down,peak_up,observed,sleep,unobserved,app_gap,received,sent
        FROM buckets WHERE grain=60 AND start>=? AND start<? ORDER BY start LIMIT 61
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, floor(lower.timeIntervalSince1970 / 60) * 60)
        sqlite3_bind_double(statement, 2, marker.timeIntervalSince1970)
        var points: [GraphPoint] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw db.error() }
            let start = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let stop = min(marker, start.addingTimeInterval(60))
            let observed = sqlite3_column_double(statement, 3)
            let missing = sqlite3_column_double(statement, 4) + sqlite3_column_double(statement, 5) + sqlite3_column_double(statement, 6)
            guard stop > start else { continue }
            points.append(GraphPoint(start: start, end: stop,
                peakDown: sqlite3_column_double(statement, 1), peakUp: sqlite3_column_double(statement, 2),
                hasMeasurements: observed > 0 || sqlite3_column_int64(statement, 7) > 0 || sqlite3_column_int64(statement, 8) > 0,
                hasGap: missing > 0.001 || observed < stop.timeIntervalSince(start) - 0.001))
        }
        return LiveGraph.window(points, ending: end)
    }
    private func tierCuts(ending upper: Double) throws -> (minute: Double, hour: Double) {
        let statement = try db.prepare("SELECT value FROM metadata WHERE key='retention_reference'")
        defer { sqlite3_finalize(statement) }
        let reference: Double
        switch sqlite3_step(statement) {
        case SQLITE_ROW: reference = max(upper, sqlite3_column_double(statement, 0))
        case SQLITE_DONE:
            // Older schema-3 databases have no pruning reference. Their saved
            // high-water timestamp supplies the best available lower bound.
            reference = max(upper, try lastRecorded()?.timeIntervalSince1970 ?? upper)
        default: throw db.error()
        }
        return (ceil((reference - Self.minuteRetention) / 3600) * 3600,
                ceil((reference - Self.hourRetention) / 86400) * 86400)
    }
    /// Aggregate disjoint retention tiers in SQLite; return approximately 360
    /// measured groups plus bounded explicit missing ranges, never all rows.
    public func chart(from requestedStart: Date?, to end: Date, limit: Int = 360) throws -> PeriodChart {
        let earliest = try db.prepare("SELECT MIN(start) FROM buckets WHERE grain=86400")
        defer { sqlite3_finalize(earliest) }
        guard sqlite3_step(earliest) == SQLITE_ROW else { throw db.error() }
        let first = sqlite3_column_type(earliest, 0) == SQLITE_NULL ? end.timeIntervalSince1970 - 3600 : sqlite3_column_double(earliest, 0)
        let lower = requestedStart?.timeIntervalSince1970 ?? min(first, end.timeIntervalSince1970 - 1)
        let upper = end.timeIntervalSince1970
        guard lower.isFinite, upper.isFinite, lower < upper else { throw HistoryError("Invalid chart range") }
        let marker = min(upper, try lastRecorded()?.timeIntervalSince1970 ?? upper)
        let cuts = try tierCuts(ending: upper)
        let minuteCut = cuts.minute, hourCut = cuts.hour
        let ranges = [(86400, lower, min(upper, hourCut)),
                      (3600, max(lower, hourCut), min(upper, minuteCut)),
                      (60, max(lower, minuteCut), upper)].filter { $0.1 < $0.2 }
        let coarse = Double(ranges.map(\.0).max() ?? 60)
        let count = max(1, min(360, limit))
        let width = max(coarse, ceil((upper - lower) / Double(count) / coarse) * coarse)
        let anchor = floor(lower / width) * width
        struct Bin { var down = 0.0, up = 0.0, observed = 0.0, missing = 0.0, measured = false }
        var bins: [Int: Bin] = [:]
        for (grain, from, to) in ranges {
            let statement = try db.prepare("""
            WITH selected AS (
              SELECT *, MIN(start+grain, ?) AS bucket_end
              FROM buckets WHERE grain=? AND start<? AND start>?
            ), clipped AS (
              SELECT *, MAX(start, ?) AS first, MIN(bucket_end, ?) AS last FROM selected
            ), weighted AS (
              SELECT *, MIN(1.0, MAX(0.0, 1.0*(last-first)/MAX(0.000000001,bucket_end-start))) AS fraction
              FROM clipped WHERE last>first
            )
            SELECT CAST((first-?)/? AS INTEGER), MAX(peak_down), MAX(peak_up),
              SUM(observed*fraction), SUM((sleep+unobserved+app_gap)*fraction),
              MAX(CASE WHEN observed>0 OR received>0 OR sent>0 THEN 1 ELSE 0 END)
            FROM weighted GROUP BY 1 ORDER BY 1
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, marker); sqlite3_bind_int(statement, 2, Int32(grain))
            sqlite3_bind_double(statement, 3, to); sqlite3_bind_double(statement, 4, from - Double(grain))
            sqlite3_bind_double(statement, 5, from); sqlite3_bind_double(statement, 6, to)
            sqlite3_bind_double(statement, 7, anchor); sqlite3_bind_double(statement, 8, width)
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw db.error() }
                let index = Int(sqlite3_column_int64(statement, 0))
                var bin = bins[index] ?? Bin()
                bin.down = max(bin.down, sqlite3_column_double(statement, 1)); bin.up = max(bin.up, sqlite3_column_double(statement, 2))
                bin.observed += sqlite3_column_double(statement, 3); bin.missing += sqlite3_column_double(statement, 4)
                bin.measured = bin.measured || sqlite3_column_int(statement, 5) != 0
                bins[index] = bin
            }
        }
        let points = bins.sorted { $0.key < $1.key }.compactMap { index, bin -> GraphPoint? in
            let first = max(lower, anchor + Double(index) * width)
            let last = min(marker, upper, anchor + Double(index + 1) * width)
            guard last > first else { return nil }
            return GraphPoint(start: Date(timeIntervalSince1970: first), end: Date(timeIntervalSince1970: last),
                peakDown: bin.down, peakUp: bin.up, hasMeasurements: bin.measured,
                hasGap: bin.missing > 0.001 || bin.observed < last - first - 0.001)
        }
        let start = Date(timeIntervalSince1970: lower)
        return PeriodChart(start: start, end: end,
            points: LiveGraph.window(points, start: start, ending: end), resolution: width)
    }
    public func today(at date: Date = Date(), calendar: Calendar = .current) throws -> HistorySummary {
        let midnight = calendar.startOfDay(for: date)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        let statement = try db.prepare("""
        SELECT COALESCE(SUM(received),0),COALESCE(SUM(sent),0),COALESCE(MAX(peak_down),0),COALESCE(MAX(peak_up),0),
        COALESCE(SUM(observed),0),COALESCE(SUM(sleep),0),COALESCE(SUM(unobserved),0),COALESCE(SUM(offline),0),COALESCE(SUM(uncertain),0),COALESCE(SUM(app_gap),0)
        FROM buckets WHERE grain=60 AND start>=? AND start<?
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, midnight.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, nextMidnight.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw db.error() }
        var result = HistorySummary()
        result.received = UInt64(max(0, sqlite3_column_int64(statement, 0))); result.sent = UInt64(max(0, sqlite3_column_int64(statement, 1)))
        result.peakDown = sqlite3_column_double(statement, 2); result.peakUp = sqlite3_column_double(statement, 3)
        result.observed = sqlite3_column_double(statement, 4); result.sleep = sqlite3_column_double(statement, 5)
        result.unobserved = sqlite3_column_double(statement, 6); result.offline = sqlite3_column_double(statement, 7)
        result.uncertain = sqlite3_column_double(statement, 8); result.appGap = sqlite3_column_double(statement, 9)
        return result
    }
    public func aggregate(from start: Date?, to end: Date) throws -> PeriodHistory {
        let upper = end.timeIntervalSince1970
        let lower = start?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        guard upper.isFinite, lower.isFinite, lower < upper else { throw HistoryError("Invalid history range") }
        let saved = try lastRecorded()
        let marker = min(upper, saved?.timeIntervalSince1970 ?? upper)
        // Cut tiers on coarser bucket boundaries, inside their retention windows.
        // Each timestamp belongs to one tier; overlapping tiers are never added.
        let cuts = try tierCuts(ending: upper)
        let minuteCut = cuts.minute, hourCut = cuts.hour
        var result = PeriodHistory(end: end, savedThrough: saved.map { min($0, end) })
        // A clock setback can mix observations from either side of the query
        // end within one aggregate bucket. Its exact timing is unrecoverable.
        result.boundaryEstimated = saved.map { $0 > end } ?? false
        var down = 0.0, up = 0.0, exactPeak = 0.0
        var wholeDown: UInt64 = 0, wholeUp: UInt64 = 0
        let ranges = [(86400, lower, min(upper, hourCut)),
                      (3600, max(lower, hourCut), min(upper, minuteCut)),
                      (60, max(lower, minuteCut), upper)]
        for (grain, from, to) in ranges where from < to {
            let statement = try db.prepare("""
            WITH selected AS (
              SELECT *, MIN(start+grain, ?) AS bucket_end FROM buckets
              WHERE grain=? AND start<? AND start>?
            ), weighted AS (
              SELECT *, MIN(1.0, MAX(0.0, 1.0*(MIN(bucket_end, ?)-MAX(start, ?)) / MAX(0.000000001, bucket_end-start))) AS fraction
              FROM selected WHERE bucket_end>?
            )
            SELECT COALESCE(SUM(CASE WHEN fraction=1 THEN received ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN fraction=1 THEN sent ELSE 0 END),0),
              COALESCE(MAX(peak_down),0), COALESCE(MAX(peak_up),0),
              COALESCE(SUM(observed*fraction),0), COALESCE(SUM(sleep*fraction),0),
              COALESCE(SUM(unobserved*fraction),0), COALESCE(SUM(offline*fraction),0),
              COALESCE(SUM(uncertain*fraction),0), COALESCE(SUM(app_gap*fraction),0),
              COUNT(*), COALESCE(MAX(CASE WHEN fraction<1 THEN 1 ELSE 0 END),0),
              COALESCE(MAX(CASE WHEN fraction=1 THEN MAX(peak_down,peak_up) ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN fraction<1 THEN received*fraction ELSE 0 END),0),
              COALESCE(SUM(CASE WHEN fraction<1 THEN sent*fraction ELSE 0 END),0)
            FROM weighted
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, marker); sqlite3_bind_int(statement, 2, Int32(grain))
            sqlite3_bind_double(statement, 3, to); sqlite3_bind_double(statement, 4, from - Double(grain))
            sqlite3_bind_double(statement, 5, to); sqlite3_bind_double(statement, 6, from)
            sqlite3_bind_double(statement, 7, from)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw db.error() }
            let received = wholeDown.addingReportingOverflow(UInt64(max(0, sqlite3_column_int64(statement, 0))))
            let sent = wholeUp.addingReportingOverflow(UInt64(max(0, sqlite3_column_int64(statement, 1))))
            guard !received.overflow, !sent.overflow else { throw HistoryError("Period byte totals exceed the supported range") }
            wholeDown = received.partialValue; wholeUp = sent.partialValue
            down += sqlite3_column_double(statement, 13); up += sqlite3_column_double(statement, 14)
            result.summary.peakDown = max(result.summary.peakDown, sqlite3_column_double(statement, 2))
            result.summary.peakUp = max(result.summary.peakUp, sqlite3_column_double(statement, 3))
            result.summary.observed += sqlite3_column_double(statement, 4)
            result.summary.sleep += sqlite3_column_double(statement, 5)
            result.summary.unobserved += sqlite3_column_double(statement, 6)
            result.summary.offline += sqlite3_column_double(statement, 7)
            result.summary.uncertain += sqlite3_column_double(statement, 8)
            result.summary.appGap += sqlite3_column_double(statement, 9)
            result.hasRecords = result.hasRecords || sqlite3_column_int64(statement, 10) > 0
            result.boundaryEstimated = result.boundaryEstimated || sqlite3_column_int(statement, 11) != 0
            exactPeak = max(exactPeak, sqlite3_column_double(statement, 12))
        }
        func bytes(_ value: Double) -> UInt64 {
            if value >= Double(UInt64.max) { return .max }
            return value.isFinite ? UInt64(max(0, value).rounded(.down)) : 0
        }
        let received = wholeDown.addingReportingOverflow(bytes(down)), sent = wholeUp.addingReportingOverflow(bytes(up))
        guard !received.overflow, !sent.overflow else { throw HistoryError("Period byte totals exceed the supported range") }
        result.summary.received = received.partialValue; result.summary.sent = sent.partialValue
        result.peakIsUpperBound = max(result.summary.peakDown, result.summary.peakUp) > exactPeak
        return result
    }
    public func events(limit: Int = 100) throws -> [HistoryEvent] {
        let statement = try db.prepare("SELECT id,date,kind,detail FROM events ORDER BY id DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(50000, max(1, limit))))
        var result: [HistoryEvent] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw db.error() }
            result.append(HistoryEvent(id: sqlite3_column_int64(statement, 0), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: String(cString: sqlite3_column_text(statement, 2)), detail: String(cString: sqlite3_column_text(statement, 3))))
        }
    }
    public func backup(to destination: URL) throws {
        try backup(to: destination, step: { sqlite3_backup_step($0, -1) })
    }
    func backup(to destination: URL, step: (OpaquePointer?) -> Int32) throws {
        guard destination.standardizedFileURL != url.standardizedFileURL else { throw HistoryError("Choose a separate backup file") }
        // Refuse replacement. The save panel asks users to choose a fresh destination.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw HistoryError("Backup destination already exists. Choose a new name.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Traffic-backup-\(UUID()).sqlite")
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: temporary.path + suffix) }
        }
        let target = try Database(path: temporary.path)
        defer { target.close() }
        guard let backup = sqlite3_backup_init(target.handle, "main", db.handle, "main") else { throw target.error() }
        let result = step(backup)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw HistoryError("Backup failed with SQLite code \(result == SQLITE_DONE ? finish : result)")
        }
        // Close SQLite before publishing. Exclusive rename atomically refuses
        // even a destination created after the initial check, without requiring
        // hard-link support from the user's chosen filesystem.
        target.close()
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw HistoryError("Could not publish backup: \(String(cString: strerror(errno)))") }
    }
    public func exportCSV(to destination: URL) throws {
        guard destination.standardizedFileURL != url.standardizedFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
            throw HistoryError("Export destination already exists. Choose a new name.")
        }
        let rows = try rows(limit: 40000)
        let events = try events(limit: 50000)
        var text = "record,date_utc,download_bytes,upload_bytes,peak_download_Bps,peak_upload_Bps,observed_seconds,sleep_seconds,unobserved_seconds,app_gap_seconds,offline_seconds,uncertain_seconds,event,detail\n"
        let formatter = ISO8601DateFormatter()
        for row in rows.reversed() {
            let s = row.summary
            text += "day,\(formatter.string(from: Date(timeIntervalSince1970: Double(row.start)))),\(s.received),\(s.sent),\(s.peakDown),\(s.peakUp),\(s.observed),\(s.sleep),\(s.unobserved),\(s.appGap),\(s.offline),\(s.uncertain),,\n"
        }
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for event in events.reversed() {
            text += "event,\(formatter.string(from: event.date)),,,,,,,,,,,\(quote(event.kind)),\(quote(event.detail))\n"
        }
        // Publish with the same exclusive rename as backup so a file created meanwhile is never replaced.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Current-export-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try text.write(to: temporary, atomically: false, encoding: .utf8)
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw HistoryError("Could not publish export: \(String(cString: strerror(errno)))") }
    }
}
